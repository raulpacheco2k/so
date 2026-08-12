#!/usr/bin/env bash

# Menu Bluetooth para i3status: dmenu no X11 (com fallback para Walker) e
# bluetoothctl como backend. Os fluxos sao lineares e previsiveis:
# - conectar e descobrir dispositivos nunca abrem um terminal;
# - parear usa um agente em segundo plano e prompts graficos;
# - um vinculo rejeitado e atualizado automaticamente quando a autenticacao falha.
# Nenhum nome de hardware e assumido; os alvos sao enderecos do BlueZ e
# destinos de audio reportados pelo servidor da sessao.
set -Eeuo pipefail
shopt -s extglob

export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=audio-lib.sh
. "$SCRIPT_DIR/audio-lib.sh"

BLUETOOTHCTL="${BLUETOOTHCTL_BIN:-${BLUETOOTHCTL:-bluetoothctl}}"
DMENU="${BLUETOOTH_MENU_BIN:-${DMENU_BIN:-/usr/bin/dmenu}}"
WALKER="${WALKER_BIN:-$HOME/.local/bin/walker}"
NOTIFY_SEND="${NOTIFY_SEND_BIN:-notify-send}"
RFKILL="${RFKILL_BIN:-rfkill}"
PKILL="${PKILL_BIN:-/usr/bin/pkill}"

SCAN_SECONDS="${BLUETOOTH_SCAN_SECONDS:-${BLUETOOTH_PAIR_SCAN_SECONDS:-15}}"
CONNECT_TIMEOUT="${BLUETOOTH_CONNECT_TIMEOUT:-12}"
CONNECT_SETTLE_SECONDS="${BLUETOOTH_CONNECT_SETTLE_SECONDS:-15}"
AGENT_TIMEOUT="${BLUETOOTH_AGENT_TIMEOUT:-45}"
AUDIO_WAIT_SECONDS="${BLUETOOTH_AUDIO_WAIT_SECONDS:-12}"

for variable_name in \
    SCAN_SECONDS CONNECT_TIMEOUT CONNECT_SETTLE_SECONDS \
    AGENT_TIMEOUT AUDIO_WAIT_SECONDS; do
    if [[ ! "${!variable_name}" =~ ^[0-9]+$ ]]; then
        case "$variable_name" in
            SCAN_SECONDS) SCAN_SECONDS=15 ;;
            CONNECT_TIMEOUT) CONNECT_TIMEOUT=12 ;;
            CONNECT_SETTLE_SECONDS) CONNECT_SETTLE_SECONDS=15 ;;
            AGENT_TIMEOUT) AGENT_TIMEOUT=45 ;;
            AUDIO_WAIT_SECONDS) AUDIO_WAIT_SECONDS=12 ;;
        esac
    fi
done

command_is_available() {
    local command_name="$1"

    if [[ "$command_name" == */* ]]; then
        [[ -x "$command_name" ]]
    else
        command -v "$command_name" >/dev/null 2>&1
    fi
}

if ! command_is_available "$BLUETOOTHCTL"; then
    exit 0
fi
if ! command_is_available timeout; then
    exit 0
fi
if ! command_is_available "$DMENU" && ! command_is_available "$WALKER"; then
    exit 0
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-i3"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
fi
LOG_FILE="$STATE_DIR/bluetooth.log"
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="/dev/null"

# O menu pode ser aberto a qualquer momento; apenas a janela do menu e mutuamente
# exclusiva (MENU_LOCK_FILE). Operacoes que alteram o estado do Bluetooth sao
# serializadas em dois niveis:
# - lock global (descritor 9): pareamento (o agente BlueZ e unico) e
#   ligar/desligar o radio;
# - lock por dispositivo: conectar, desconectar, esquecer e reparar um endereco
#   especifico, permitindo operar outros dispositivos durante uma conexao.
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/bluetooth-menu-$(id -u).lock"
MENU_LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/bluetooth-menu-ui-$(id -u).lock"
exec 9>"$LOCK_FILE"
ACTION_LOCK_HELD=0

log_event() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

notify_user() {
    local title="$1"
    local body="$2"

    if command_is_available "$NOTIFY_SEND"; then
        "$NOTIFY_SEND" -a Bluetooth -u normal "$title" "$body" \
            >/dev/null 2>&1 || true
    fi
}

acquire_action_lock() {
    if ((ACTION_LOCK_HELD == 1)); then
        return 0
    fi
    if flock -n 9; then
        ACTION_LOCK_HELD=1
        return 0
    fi
    notify_user 'Bluetooth ocupado' \
        'Outra ação Bluetooth está em andamento. Tente novamente ao terminar.'
    return 1
}

release_action_lock() {
    if ((ACTION_LOCK_HELD == 1)); then
        flock -u 9 2>/dev/null || true
        ACTION_LOCK_HELD=0
    fi
}

DEVICE_LOCK_FD=""
DEVICE_LOCK_ADDR=""

device_lock_path() {
    local address="$1"

    printf '%s/bluetooth-menu-dev-%s-%s.lock' \
        "${XDG_RUNTIME_DIR:-/tmp}" "$(id -u)" "${address//:/_}"
}

# Serializa operacoes sobre um unico endereco, sem bloquear outros dispositivos.
# A chamada nao e reentrante: o chamador deve liberar o lock antes de adquirir
# um lock de outro endereco (ex.: o reparo libera o endereco antigo antes de
# parear o novo endereco descoberto).
acquire_device_lock() {
    local address="$1"
    local label="$2"
    local lock_path

    lock_path="$(device_lock_path "$address")"
    if ! exec {DEVICE_LOCK_FD}>"$lock_path"; then
        DEVICE_LOCK_FD=""
        notify_user 'Dispositivo ocupado' \
            "Não foi possível bloquear $label. Tente novamente."
        return 1
    fi
    if ! flock -n "$DEVICE_LOCK_FD"; then
        exec {DEVICE_LOCK_FD}>&-
        DEVICE_LOCK_FD=""
        log_event "dispositivo ocupado: $address ($label)"
        notify_user 'Dispositivo ocupado' \
            "Já existe uma operação em andamento com $label. Tente novamente ao terminar."
        return 1
    fi
    DEVICE_LOCK_ADDR="$address"
    return 0
}

release_device_lock() {
    if [[ -n "$DEVICE_LOCK_FD" ]]; then
        flock -u "$DEVICE_LOCK_FD" 2>/dev/null || true
        exec {DEVICE_LOCK_FD}>&- 2>/dev/null || true
    fi
    DEVICE_LOCK_FD=""
    DEVICE_LOCK_ADDR=""
}

# Sessao curta usada apenas para consultas e comandos que nao exigem agente.
bt_batch() {
    local timeout_seconds="$1"
    shift

    (
        exec 9>&-
        {
            printf '%s\n' "$@"
            printf 'quit\n'
        } | timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
            "$BLUETOOTHCTL" 2>/dev/null || true
    )
}

bt_command() {
    local timeout_seconds="$1"
    shift

    (
        exec 9>&-
        timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
            "$BLUETOOTHCTL" "$@" 2>&1
    )
}

refresh_status() {
    if command_is_available "$PKILL"; then
        "$PKILL" -USR1 -x i3status 2>/dev/null || true
    fi
}

unblock_bluetooth() {
    if command_is_available "$RFKILL"; then
        "$RFKILL" unblock bluetooth >/dev/null 2>&1 || true
    fi
}

ensure_radio() {
    local output

    unblock_bluetooth
    if ! output="$(bt_command 5 power on)"; then
        log_event "power on falhou: $output"
        notify_user 'Bluetooth indisponível' \
            "Não foi possível ligar o rádio. Consulte $LOG_FILE."
        return 1
    fi
}

device_info() {
    local address="$1"

    bt_command 4 info "$address" || true
}

device_is_connected() {
    local address="$1"
    local info

    if bt_batch 4 'devices Connected' \
        | grep -Eq "^[[:space:]]*Device[[:space:]]+${address}([[:space:]]|$)"; then
        return 0
    fi
    info="$(device_info "$address")"
    grep -Eq '^[[:space:]]*Connected:[[:space:]]+yes' <<<"$info"
}

device_is_paired() {
    local address="$1"
    local output

    output="$(bt_batch 5 'devices Paired')"
    if ! grep -Eq '^[[:space:]]*Device[[:space:]]+' <<<"$output"; then
        output="$(bt_batch 5 paired-devices)"
    fi
    grep -Eq "^[[:space:]]*Device[[:space:]]+${address}([[:space:]]|$)" \
        <<<"$output"
}

wait_for_connection() {
    local address="$1"
    local deadline=$((SECONDS + CONNECT_SETTLE_SECONDS))
    local info connected_seen=0 services_seen=0

    while ((SECONDS < deadline)); do
        info="$(device_info "$address")"
        if grep -Eq '^[[:space:]]*Connected:[[:space:]]+yes' <<<"$info"; then
            connected_seen=1
        else
            connected_seen=0
        fi
        if grep -Eq '^[[:space:]]*ServicesResolved:' <<<"$info"; then
            services_seen=1
            if ((connected_seen == 1)) \
                && grep -Eq '^[[:space:]]*ServicesResolved:[[:space:]]+yes' <<<"$info"; then
                return 0
            fi
        fi
        sleep 1
    done

    # BlueZ antigo pode nao expor ServicesResolved. Nessa situacao exigimos
    # que o link permaneça conectado durante toda a janela de estabilizacao.
    ((connected_seen == 1 && services_seen == 0))
}

connection_error_summary() {
    local output="$1"
    local summary

    summary="$(printf '%s\n' "$output" | awk 'NF { line = $0 } END { print line }')"
    printf '%s' "${summary:-operação não confirmada}"
}

MENU_LABELS=()
MENU_KINDS=()
MENU_VALUES=()

add_entry() {
    MENU_LABELS+=("$1")
    MENU_KINDS+=("$2")
    MENU_VALUES+=("${3:-}")
}

declare -A DEVICE_NAMES=()
declare -A DEVICE_PAIRED=()
declare -A DEVICE_DISCOVERED=()
declare -A DEVICE_CONNECTED=()
declare -A DEVICE_TRANSPORTS=()
declare -A NAME_COUNTS=()

load_device_lines() {
    local output="$1"
    local row address name

    while IFS= read -r row; do
        if [[ "$row" =~ ^[[:space:]]*Device[[:space:]]+([[:xdigit:]:]{17})([[:space:]]+(.*))?$ ]]; then
            address="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[3]-}"
            name="${name##+([[:space:]])}"
            name="${name%%+([[:space:]])}"
            DEVICE_NAMES["$address"]="${name:-$address}"
            DEVICE_DISCOVERED["$address"]=1
        fi
    done <<<"$output"
}

load_connected_lines() {
    local output="$1"
    local row address name

    while IFS= read -r row; do
        if [[ "$row" =~ ^[[:space:]]*Device[[:space:]]+([[:xdigit:]:]{17})([[:space:]]+(.*))?$ ]]; then
            address="${BASH_REMATCH[1]}"
            name="${BASH_REMATCH[3]-}"
            name="${name##+([[:space:]])}"
            name="${name%%+([[:space:]])}"
            DEVICE_CONNECTED["$address"]=1
            if [[ -n "$name" ]]; then
                DEVICE_NAMES["$address"]="$name"
            fi
        fi
    done <<<"$output"
}

load_transport_lines() {
    local output="$1"
    local row address transport current

    while IFS= read -r row; do
        if [[ "$row" =~ (LE|BREDR)[[:space:]]+/org/bluez/hci[0-9]+/dev_([[:xdigit:]_]+) ]]; then
            transport="${BASH_REMATCH[1]}"
            address="${BASH_REMATCH[2]//_/:}"
            current="${DEVICE_TRANSPORTS[$address]-}"
            if [[ "$transport" == BREDR && "$current" == LE ]]; then
                DEVICE_TRANSPORTS["$address"]='LE + BR/EDR'
            elif [[ -z "$current" || "$transport" == BREDR ]]; then
                DEVICE_TRANSPORTS["$address"]="$transport"
            fi
        fi
    done <<<"$output"
}

device_label() {
    local address="$1"
    local name="${DEVICE_NAMES[$address]-$address}"

    if [[ "$name" == "$address" || "${NAME_COUNTS[$name]:-0}" -gt 1 ]]; then
        printf '%s · %s' "$name" "$address"
    else
        printf '%s' "$name"
    fi
}

# Exibe um menu dmenu e usa Walker somente quando dmenu nao esta disponivel.
# A funcao retorna o indice selecionado; fechar a janela retorna uma linha vazia.
menu_choice() {
    local prompt="$1"
    shift
    local labels=("$@")
    local selected="" choice="" lines
    local index menu_lock_fd

    # Evita duas janelas de menu simultaneas, sem compartilhar o lock das
    # acoes. Assim uma nova invocacao pode exibir o menu durante uma conexao.
    if ! exec {menu_lock_fd}>"$MENU_LOCK_FILE"; then
        printf '\n'
        return 0
    fi
    if ! flock -n "$menu_lock_fd"; then
        exec {menu_lock_fd}>&-
        printf '\n'
        return 0
    fi

    lines=$(( ${#labels[@]} < 12 ? ${#labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    if command_is_available "$DMENU"; then
        selected="$(
            exec 9>&-
            printf '%s\n' "${labels[@]}" \
                | "$DMENU" -i -l "$lines" -p "$prompt" \
                    -fn 'JetBrainsMono Nerd Font:size=10' \
                    -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000'
        )" || true
        for index in "${!labels[@]}"; do
            if [[ "${labels[$index]}" == "$selected" ]]; then
                choice="$index"
                break
            fi
        done
    elif command_is_available "$WALKER"; then
        choice="$(
            exec 9>&-
            printf '%s\n' "${labels[@]}" \
                | "$WALKER" --dmenu --index --exit --theme vantablack \
                    --width 644 --height 570 --placeholder "$prompt"
        )" || true
    fi
    flock -u "$menu_lock_fd" 2>/dev/null || true
    exec {menu_lock_fd}>&-
    printf '%s\n' "$choice"
}

agent_confirm() {
    local prompt="$1"
    local choice

    # Esta funcao e chamada por command substitution; somente o menu
    # principal deve conservar o descritor do lock.
    exec 9>&-
    choice="$(menu_choice "$prompt" 'Confirmar' 'Cancelar')"
    case "$choice" in
        0) printf 'yes\n' ;;
        *) printf 'cancel\n' ;;
    esac
}

agent_pin() {
    local prompt="$1"
    local selected=""

    # Esta funcao e chamada por command substitution; somente o menu
    # principal deve conservar o descritor do lock.
    exec 9>&-
    # dmenu permite escolher 0000 ou digitar outro valor. Walker, usado como
    # fallback, oferece a opcao comum sem inventar um PIN para o dispositivo.
    if command_is_available "$DMENU"; then
        selected="$(
            exec 9>&-
            printf '%s\n' '0000' 'Cancelar' \
                | "$DMENU" -i -l 2 -p "$prompt" \
                    -fn 'JetBrainsMono Nerd Font:size=10' \
                    -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000'
        )" || true
        if [[ "$selected" =~ ^[0-9]{1,16}$ ]]; then
            printf '%s\n' "$selected"
        else
            printf 'cancel\n'
        fi
        return 0
    fi

    if [[ "$(menu_choice "$prompt" '0000' 'Cancelar')" == 0 ]]; then
        printf '0000\n'
    else
        printf 'cancel\n'
    fi
}

strip_ansi_sequences() {
    local text="$1"
    local sequence
    local csi_pattern=$'\033''\[[0-?]*[ -/]*[@-~]'

    # O bluetoothctl colore partes da saida do agente com sequencias CSI.
    # Remova-as antes de procurar os textos e codigos exibidos pelo BlueZ.
    while [[ "$text" =~ $csi_pattern ]]; do
        sequence="${BASH_REMATCH[0]}"
        text="${text//"$sequence"/}"
    done
    REPLY="$text"
}

# DisplayPasskey nao espera uma resposta do agente: o BlueZ chama o agente
# novamente conforme os digitos entram no teclado. A janela precisa, portanto,
# apenas mostrar o codigo e permanecer independente do loop que consome o
# bluetoothctl. PASSKEY_LAST_VALUE evita reabrir a janela para os eventos
# repetidos emitidos durante a mesma autenticacao.
PASSKEY_WINDOW_PID=""
PASSKEY_LAST_VALUE=""

passkey_window_close() {
    local window_pid="$PASSKEY_WINDOW_PID"

    PASSKEY_WINDOW_PID=""
    if [[ "$window_pid" =~ ^[0-9]+$ ]]; then
        if kill -0 "$window_pid" 2>/dev/null; then
            kill "$window_pid" 2>/dev/null || true
        fi
        wait "$window_pid" 2>/dev/null || true
    fi
}

passkey_window_show() {
    local passkey="$1"
    local message="PIN: $passkey — digite no K380 e pressione Enter"

    # O mesmo DisplayPasskey pode ser emitido varias vezes, inclusive depois
    # de o usuario fechar a janela com Enter. Nao crie outra janela nesse caso.
    if [[ "$PASSKEY_LAST_VALUE" == "$passkey" ]]; then
        return 0
    fi
    PASSKEY_LAST_VALUE="$passkey"

    if [[ -n "$PASSKEY_WINDOW_PID" ]]; then
        passkey_window_close
    fi

    if command_is_available "$DMENU"; then
        # A linha vazia fornece uma entrada para o dmenu e o EOF deixa a
        # janela interativa. O pipeline inteiro roda em segundo plano para
        # que o agente continue consumindo os eventos do bluetoothctl.
        (
            exec 9>&-
            exec "$DMENU" -i -l 1 -p "$message" \
                -fn 'JetBrainsMono Nerd Font:size=10' \
                -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000' \
                </dev/null >/dev/null 2>&1
        ) &
        PASSKEY_WINDOW_PID=$!
        return 0
    fi

    if command_is_available "$WALKER"; then
        (
            exec 9>&-
            exec "$WALKER" --dmenu --exit --theme vantablack \
                --width 644 --height 130 --placeholder "$message" \
                </dev/null >/dev/null 2>&1
        ) &
        PASSKEY_WINDOW_PID=$!
    fi
}

trap 'cleanup_discovery; passkey_window_close' EXIT

# Pareia em segundo plano com um agente residente. A saida do bluetoothctl e
# consumida aqui para responder prompts sem abrir um terminal. Retorna 0 quando
# a conexao foi estabelecida, 2 quando o usuario cancelou e 1 em falha.
pair_with_agent() {
    local target="$1"
    local timeout_seconds="$2"
    local bt_in="" bt_out="" bt_pid="" byte buffer=""
    local result="" answer="" passkey=""
    local normalized_buffer="" normalized_event_line=""
    local deadline waited
    local trust_sent=0 failed_pending=0

    PASSKEY_LAST_VALUE=""

    if ! ensure_radio; then
        return 1
    fi

    coproc BTAGENT { exec 9>&-; exec "$BLUETOOTHCTL" 2>&1; }
    bt_in="${BTAGENT[1]}"
    bt_out="${BTAGENT[0]}"
    bt_pid="$BTAGENT_PID"
    sleep 0.25

    # O agente precisa permanecer vivo durante toda a autenticacao. scan on
    # tambem garante um advertising report ativo para dispositivos LE.
    printf 'agent on\ndefault-agent\nscan on\npair %s\n' "$target" \
        >&"$bt_in" 2>/dev/null || true

    deadline=$((SECONDS + timeout_seconds))
    while ((SECONDS < deadline)); do
        while IFS= read -r -t 1 -N 1 -u "$bt_out" byte 2>/dev/null; do
            buffer+="$byte"
            if (( ${#buffer} > 512 )); then
                buffer="${buffer: -480}"
            fi

            strip_ansi_sequences "$buffer"
            normalized_buffer="$REPLY"
            normalized_event_line="${normalized_buffer##*$'\n'}"
            if [[ "$normalized_event_line" != *"Request PIN code"* \
                && "$normalized_event_line" != *"Enter PIN code"* \
                && "$normalized_event_line" =~ (Passkey|PIN[[:space:]]+code):[[:space:]]*([0-9]{6}) ]]; then
                passkey_window_show "${BASH_REMATCH[2]}"
                buffer=""
            elif [[ "$normalized_buffer" == *"Request PIN code"* \
                || "$normalized_buffer" == *"Enter PIN code"* ]]; then
                answer="$(agent_pin "PIN do Bluetooth para $target")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                    passkey_window_close
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$normalized_buffer" == *"Confirm passkey"* ]]; then
                passkey=""
                if [[ "$normalized_buffer" =~ [Pp]asskey[[:space:]]+([0-9]{1,6}) ]]; then
                    passkey="${BASH_REMATCH[1]}"
                fi
                answer="$(agent_confirm \
                    "Confirme a passkey ${passkey:-mostrada no dispositivo}")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                    passkey_window_close
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$normalized_buffer" == *"Enter passkey"* ]]; then
                answer="$(agent_pin 'Digite a passkey exibida no dispositivo')"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                    passkey_window_close
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$normalized_buffer" == *"Authorize"* ]]; then
                answer="$(agent_confirm "Autorizar o dispositivo $target?")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                    passkey_window_close
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$normalized_buffer" == *"Pairing successful"* ]]; then
                passkey_window_close
                if ((trust_sent == 0)); then
                    printf 'trust %s\nconnect %s\n' "$target" "$target" \
                        >&"$bt_in" 2>/dev/null || true
                    trust_sent=1
                fi
                buffer=""
            elif [[ "$normalized_buffer" == *"AlreadyExists"* ]]; then
                passkey_window_close
                # Corrida ou estado antigo: se ja existe, o proximo passo e
                # conectar, nunca abrir outro fluxo de pareamento.
                if ((trust_sent == 0)); then
                    printf 'trust %s\nconnect %s\n' "$target" "$target" \
                        >&"$bt_in" 2>/dev/null || true
                    trust_sent=1
                fi
                failed_pending=0
                buffer=""
            elif [[ "$normalized_buffer" == *"Connection successful"* ]]; then
                passkey_window_close
                result="connected"
                buffer=""
            elif [[ "$normalized_buffer" == *"AuthenticationFailed"* \
                || "$normalized_buffer" == *"Failed to connect"* \
                || "$normalized_buffer" == *"No agent available"* \
                || "$normalized_buffer" == *"Canceled"* ]]; then
                passkey_window_close
                result="failed"
                buffer=""
            elif [[ "$normalized_buffer" == *"Failed to pair"* ]]; then
                # Aguarda o restante da mesma linha para distinguir
                # AlreadyExists de um erro real de pareamento.
                failed_pending=1
            fi
            [[ -n "$result" ]] && break
        done

        if [[ -z "$result" ]] \
            && grep -Eq '^[[:space:]]*Paired:[[:space:]]+yes' \
                <<<"$(device_info "$target")" \
            && device_is_connected "$target"; then
            result="connected"
        fi
        if [[ -n "$result" ]]; then
            break
        fi
        sleep 0.5
    done

    if [[ -z "$result" ]]; then
        if ((failed_pending == 1)); then
            result="failed"
        else
            result="failed"
        fi
    fi

    printf 'scan off\nquit\n' >&"$bt_in" 2>/dev/null || true
    passkey_window_close
    exec {bt_in}>&- 2>/dev/null || true
    exec {bt_out}>&- 2>/dev/null || true

    waited=0
    while kill -0 "$bt_pid" 2>/dev/null && ((waited < 10)); do
        sleep 0.5
        waited=$((waited + 1))
    done
    if kill -0 "$bt_pid" 2>/dev/null; then
        kill "$bt_pid" 2>/dev/null || true
    fi
    wait "$bt_pid" 2>/dev/null || true

    if [[ "$result" == connected ]]; then
        return 0
    fi
    if [[ "$result" == cancelled ]]; then
        return 2
    fi
    return 1
}

# Procura um endpoint bluez pelo identificador reportado pelo servidor. O
# fallback para um unico endpoint evita depender do nome do fone, mas nunca
# escolhe nodes MIDI ou monitores.
find_bluetooth_endpoint() {
    local direction="$1"
    local address="$2"
    local normalized="${address//:/_}"
    local token name description active_port ports
    local exact="" only="" count=0

    while IFS=$'\t' read -r token name description active_port ports; do
        [[ -n "$token" ]] || continue
        [[ "$name" == *bluez* && "$name" != *midi* ]] || continue
        [[ "$name" != *.monitor ]] || continue
        count=$((count + 1))
        only="$token\t$description"
        if [[ "$name" == *"$normalized"* ]]; then
            exact="$token\t$description"
        fi
    done < <(audio_list "$direction")

    if [[ -n "$exact" ]]; then
        printf '%b\n' "$exact"
    elif ((count == 1)); then
        printf '%b\n' "$only"
    fi
}

integrate_audio() {
    local address="$1"
    local label="$2"
    local sink_info="" source_info=""
    local sink_token="" sink_description=""
    local source_token="" source_description=""
    local moved_sink="" moved_source="" body=""
    local device_details=""
    local sink_ok=0 source_ok=0
    local deadline=$((SECONDS + AUDIO_WAIT_SECONDS))

    device_details="$(device_info "$address")"
    if ! device_has_audio_profile "$device_details"; then
        notify_user 'Bluetooth sem perfil de áudio' \
            "$label está conectado, mas não anunciou um perfil de áudio utilizável."
        log_event "dispositivo sem perfil de audio: $address ($label)"
        audio_refresh_status
        return 0
    fi

    if [[ "$(audio_backend)" == none ]]; then
        notify_user 'Bluetooth conectado' \
            "$label conectou, mas nenhum servidor de áudio está ativo."
        log_event "sem servidor de audio para $address ($label)"
        return 1
    fi

    while ((SECONDS < deadline)); do
        sink_info="$(find_bluetooth_endpoint sink "$address")"
        if [[ -n "$sink_info" ]]; then
            IFS=$'\t' read -r sink_token sink_description <<<"$sink_info"
            if audio_set_default sink "$sink_token" >/dev/null 2>&1; then
                sink_ok=1
            fi
        fi

        source_info="$(find_bluetooth_endpoint source "$address")"
        if [[ -n "$source_info" ]]; then
            IFS=$'\t' read -r source_token source_description <<<"$source_info"
            if audio_set_default source "$source_token" >/dev/null 2>&1; then
                source_ok=1
            fi
        fi

        if ((sink_ok == 1 || source_ok == 1)); then
            if ((sink_ok == 1)); then
                moved_sink="$(audio_move_streams sink "$sink_token")"
                body+=" Saída: ${sink_description:-$sink_token}"
                log_event "audio sink padrao aplicado: $address -> $sink_token"
            fi
            if ((source_ok == 1)); then
                moved_source="$(audio_move_streams source "$source_token")"
                body+=" Entrada: ${source_description:-$source_token}"
                log_event "audio source padrao aplicado: $address -> $source_token"
            fi
            if [[ "$moved_sink" =~ ^[0-9]+$ && "$moved_sink" -gt 0 ]]; then
                body+=" ($moved_sink aplicações de saída movidas)"
            fi
            if [[ "$moved_source" =~ ^[0-9]+$ && "$moved_source" -gt 0 ]]; then
                body+=" ($moved_source aplicações de entrada movidas)"
            fi
            notify_user 'Bluetooth conectado' "$label.$body"
            audio_refresh_status
            return 0
        fi
        sleep 1
    done

    if ! grep -Eqi 'UUID: (Audio Sink|Audio Source|Headset|Handsfree|Audio Stream Control|Published Audio)' \
        <<<"$device_details"; then
        notify_user 'Bluetooth sem perfil de áudio' \
            "$label está conectado, mas não anunciou um perfil de áudio utilizável."
    else
        notify_user 'Bluetooth conectado' \
            "$label conectou, mas a saída de áudio Bluetooth não foi criada."
    fi
    log_event "sem sink Bluetooth para $address ($label)"
    audio_refresh_status
    return 1
}

device_has_audio_profile() {
    local device_details="$1"

    grep -Eiq '^[[:space:]]*UUID:.*(Audio Sink|Audio Source|Headset|Handsfree|Audio Stream Control|Published Audio|A2DP|BAP|HFP|HSP)' \
        <<<"$device_details"
}

connection_error_is_auth() {
    local output="$1"

    grep -Eiq 'AuthenticationFailed|NotAuthorized|not[[:space:]_-]*authorized|authentication|bond|link[[:space:]_-]*key|passkey' \
        <<<"$output"
}

connect_device() {
    local address="$1"
    local allow_rebind="${2:-1}"
    local label="${DEVICE_NAMES[$address]-$address}"
    local output="" last_error=""
    local attempt auth_failure=0

    if ! ensure_radio; then
        return 1
    fi
    if ! acquire_device_lock "$address" "$label"; then
        return 1
    fi

    # Conectar um dispositivo pareado nao inicia pareamento, exceto quando
    # uma falha de autenticacao exigir a atualizacao automatica do vinculo.
    bt_command 5 trust "$address" >/dev/null 2>&1 || true
    for ((attempt = 1; attempt <= 2; attempt++)); do
        if output="$(bt_command "$CONNECT_TIMEOUT" connect "$address")" \
            && wait_for_connection "$address"; then
            log_event "conectado: $address ($label), tentativa $attempt"
            refresh_status
            integrate_audio "$address" "$label" || true
            release_device_lock
            return 0
        fi
        last_error="$(connection_error_summary "$output")"
        if connection_error_is_auth "$output"; then
            auth_failure=1
        fi
        log_event "tentativa $attempt falhou para $address ($label): $last_error"
        ((attempt < 2)) && sleep 1
    done

    if ((auth_failure == 1 && allow_rebind == 1)); then
        release_device_lock
        if rebind_device "$address" "$label"; then
            return 0
        fi
        notify_user 'Falha ao conectar Bluetooth' \
            "Não foi possível atualizar o vínculo de $label. Tente conectar novamente."
        return 1
    fi

    release_device_lock
    notify_user 'Falha ao conectar Bluetooth' \
        "$label não estabilizou. Tente conectar novamente."
    return 1
}

DISCOVERY_SCAN_PID=""
DISCOVERY_SCAN_INPUT=""
DISCOVERY_SCAN_DIR=""
DISCOVERY_SCAN_OUTPUT=""
DISCOVERY_MENU_PID=""
DISCOVERY_MENU_RESULT=""
DISCOVERY_MENU_LOCK_FD=""
DISCOVERY_SNAPSHOT=""
DISCOVERY_LABELS=()
DISCOVERY_ADDRESSES=()
DISCOVERY_MATCHING_ADDRESSES=()

discovery_process_is_alive() {
    local process_pid="$1"
    local process_state

    [[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$process_pid" 2>/dev/null || return 1
    process_state="$(ps -o stat= -p "$process_pid" 2>/dev/null || true)"
    [[ "$process_state" != Z* ]]
}

stop_discovery_scan() {
    local input_fd="$DISCOVERY_SCAN_INPUT"
    local scan_pid="$DISCOVERY_SCAN_PID"
    local waited=0

    if [[ "$input_fd" =~ ^[0-9]+$ ]]; then
        printf 'scan off\nquit\n' >&"$input_fd" 2>/dev/null || true
        exec {input_fd}>&- 2>/dev/null || true
    fi
    DISCOVERY_SCAN_INPUT=""

    if [[ "$scan_pid" =~ ^[0-9]+$ ]]; then
        while discovery_process_is_alive "$scan_pid" && ((waited < 30)); do
            sleep 0.1
            waited=$((waited + 1))
        done
        if discovery_process_is_alive "$scan_pid"; then
            kill "$scan_pid" 2>/dev/null || true
        fi
        wait "$scan_pid" 2>/dev/null || true
    fi
    DISCOVERY_SCAN_PID=""
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

    if [[ "$DISCOVERY_MENU_LOCK_FD" =~ ^[0-9]+$ ]]; then
        flock -u "$DISCOVERY_MENU_LOCK_FD" 2>/dev/null || true
        exec {DISCOVERY_MENU_LOCK_FD}>&-
    fi
    DISCOVERY_MENU_LOCK_FD=""
}

cleanup_discovery() {
    close_discovery_menu
    stop_discovery_scan
    if [[ -n "$DISCOVERY_SCAN_DIR" ]]; then
        rm -rf -- "$DISCOVERY_SCAN_DIR" 2>/dev/null || true
    fi
    DISCOVERY_SCAN_DIR=""
    DISCOVERY_SCAN_OUTPUT=""
    DISCOVERY_MENU_RESULT=""
}

start_discovery_scan() {
    local scan_dir="$1"

    DISCOVERY_SCAN_DIR="$scan_dir"
    DISCOVERY_SCAN_OUTPUT="$scan_dir/bluetoothctl.log"
    : >"$DISCOVERY_SCAN_OUTPUT"
    coproc DISCOVERY_BT {
        exec 9>&-
        exec "$BLUETOOTHCTL" >"$DISCOVERY_SCAN_OUTPUT" 2>&1
    }
    DISCOVERY_SCAN_INPUT="${DISCOVERY_BT[1]}"
    DISCOVERY_SCAN_PID="$DISCOVERY_BT_PID"
    printf 'scan on\n' >&"$DISCOVERY_SCAN_INPUT" 2>/dev/null || true
}

build_discovery_entries() {
    local output="$1"
    local preferred_name="${2:-}"
    local row address name transport
    local -a sorted_addresses=()
    local -A seen_addresses=()

    DISCOVERY_LABELS=()
    DISCOVERY_ADDRESSES=()
    DISCOVERY_MATCHING_ADDRESSES=()

    while IFS= read -r row; do
        if [[ "$row" =~ ^[[:space:]]*Device[[:space:]]+([[:xdigit:]:]{17})([[:space:]]+(.*))?$ ]]; then
            address="${BASH_REMATCH[1]}"
            [[ -n "${seen_addresses[$address]+present}" ]] && continue
            [[ -n "${DEVICE_PAIRED[$address]+present}" ]] && continue
            seen_addresses["$address"]=1
            name="${BASH_REMATCH[3]-}"
            name="${name##+([[:space:]])}"
            name="${name%%+([[:space:]])}"
            DEVICE_NAMES["$address"]="${name:-$address}"
        fi
    done <<<"$output"

    if ((${#seen_addresses[@]} > 0)); then
        mapfile -t sorted_addresses < <(printf '%s\n' "${!seen_addresses[@]}" | sort)
    fi
    for address in "${sorted_addresses[@]}"; do
        name="${DEVICE_NAMES[$address]-$address}"
        transport="${DEVICE_TRANSPORTS[$address]-unknown}"
        DISCOVERY_ADDRESSES+=("$address")
        DISCOVERY_LABELS+=("󰂯  $name [$transport] · $address")
        if [[ -n "$preferred_name" && "$name" == "$preferred_name" ]]; then
            DISCOVERY_MATCHING_ADDRESSES+=("$address")
        fi
    done

    if ((${#DISCOVERY_LABELS[@]} == 0)); then
        DISCOVERY_SNAPSHOT='__empty__'
    else
        DISCOVERY_SNAPSHOT="$(printf '%s\n' "${DISCOVERY_LABELS[@]}")"
    fi
}

refresh_discovery_entries() {
    local discovery=""

    DEVICE_TRANSPORTS=()
    if [[ -n "$DISCOVERY_SCAN_OUTPUT" && -f "$DISCOVERY_SCAN_OUTPUT" ]]; then
        load_transport_lines "$(<"$DISCOVERY_SCAN_OUTPUT")"
    fi
    discovery="$(bt_batch 3 devices)"
    build_discovery_entries "$discovery" "${DISCOVERY_PREFERRED_NAME:-}"
}

launch_discovery_menu() {
    local input_file="$DISCOVERY_SCAN_DIR/menu.in"
    local result_file="$DISCOVERY_SCAN_DIR/menu.out"
    local lines
    local -a menu_labels=()

    if ! exec {DISCOVERY_MENU_LOCK_FD}>"$MENU_LOCK_FILE"; then
        DISCOVERY_MENU_LOCK_FD=""
        return 1
    fi
    if ! flock -n "$DISCOVERY_MENU_LOCK_FD"; then
        exec {DISCOVERY_MENU_LOCK_FD}>&-
        DISCOVERY_MENU_LOCK_FD=""
        return 1
    fi

    if ((${#DISCOVERY_LABELS[@]} == 0)); then
        menu_labels=('Procurando dispositivos...')
    else
        menu_labels=("${DISCOVERY_LABELS[@]}")
    fi
    lines=$(( ${#menu_labels[@]} < 12 ? ${#menu_labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    printf '%s\n' "${menu_labels[@]}" >"$input_file"
    : >"$result_file"
    (
        exec 9>&-
        exec "$DMENU" -i -l "$lines" -p 'Bluetooth > Conectar novo dispositivo' \
            -fn 'JetBrainsMono Nerd Font:size=10' \
            -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000' \
            <"$input_file" >"$result_file" 2>/dev/null
    ) &
    DISCOVERY_MENU_PID=$!
    DISCOVERY_MENU_RESULT="$result_file"
}

selected_discovery_address() {
    local selected="$1"
    local index

    for index in "${!DISCOVERY_LABELS[@]}"; do
        if [[ "${DISCOVERY_LABELS[$index]}" == "$selected" ]]; then
            printf '%s\n' "${DISCOVERY_ADDRESSES[$index]}"
            return 0
        fi
    done
    return 1
}

preferred_discovery_address() {
    local preferred_address="$1"
    local address

    [[ -n "$preferred_address" ]] || return 1
    for address in "${DISCOVERY_ADDRESSES[@]}"; do
        if [[ "$address" == "$preferred_address" ]]; then
            printf '%s\n' "$address"
            return 0
        fi
    done
    return 1
}

scan_for_new_device_blocking() {
    local preferred_address="${1:-}"
    local preferred_name="${2:-}"
    local discovery="" choice

    DISCOVERED_TARGET=""
    if ! ensure_radio; then
        return 1
    fi
    notify_user 'Bluetooth' "Procurando novos dispositivos por ${SCAN_SECONDS}s."
    discovery="$(
        exec 9>&-
        {
            printf 'scan on\n'
            sleep "$SCAN_SECONDS"
            printf 'scan off\nquit\n'
        } | timeout --signal=TERM --kill-after=2 "$((SCAN_SECONDS + 5))" \
            "$BLUETOOTHCTL" 2>&1
    )" || true
    DEVICE_TRANSPORTS=()
    log_event "busca concluída: ${discovery:-sem saída}"
    load_transport_lines "$discovery"
    discovery="$(bt_batch 6 devices)"
    load_transport_lines "$discovery"
    build_discovery_entries "$discovery" "$preferred_name"

    if ((${#DISCOVERY_ADDRESSES[@]} == 0)); then
        notify_user 'Bluetooth' 'Nenhum dispositivo novo foi encontrado.'
        return 1
    fi
    if preferred_discovery_address "$preferred_address" >/dev/null 2>&1; then
        DISCOVERED_TARGET="$preferred_address"
        return 0
    fi
    if ((${#DISCOVERY_MATCHING_ADDRESSES[@]} == 1)); then
        DISCOVERED_TARGET="${DISCOVERY_MATCHING_ADDRESSES[0]}"
        return 0
    fi
    choice="$(menu_choice 'Bluetooth > Conectar novo dispositivo' "${DISCOVERY_LABELS[@]}")"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] \
        || ((choice >= ${#DISCOVERY_ADDRESSES[@]})); then
        return 1
    fi
    DISCOVERED_TARGET="${DISCOVERY_ADDRESSES[$choice]}"
}

scan_for_new_device_realtime() {
    local preferred_address="${1:-}"
    local preferred_name="${2:-}"
    local scan_dir selected target current_snapshot previous_snapshot

    DISCOVERED_TARGET=""
    DISCOVERY_PREFERRED_NAME="$preferred_name"
    if ! ensure_radio; then
        return 1
    fi
    scan_dir="$(mktemp -d "$STATE_DIR/bluetooth-scan.XXXXXX")"
    start_discovery_scan "$scan_dir"
    # O primeiro menu aparece com esta linha antes mesmo da primeira consulta.
    build_discovery_entries '' "$preferred_name"
    if ! launch_discovery_menu; then
        cleanup_discovery
        return 1
    fi

    while :; do
        if ! discovery_process_is_alive "$DISCOVERY_MENU_PID"; then
            wait "$DISCOVERY_MENU_PID" 2>/dev/null || true
            selected="$(<"$DISCOVERY_MENU_RESULT")"
            if [[ -z "$selected" || "$selected" == 'Procurando dispositivos...' ]]; then
                cleanup_discovery
                return 1
            fi
            refresh_discovery_entries
            if target="$(selected_discovery_address "$selected")"; then
                DISCOVERED_TARGET="$target"
                cleanup_discovery
                return 0
            fi
            # O dispositivo pode ter desaparecido entre a seleção e a consulta.
            launch_discovery_menu
            continue
        fi

        previous_snapshot="$DISCOVERY_SNAPSHOT"
        refresh_discovery_entries
        if preferred_discovery_address "$preferred_address" >/dev/null 2>&1; then
            DISCOVERED_TARGET="$preferred_address"
            cleanup_discovery
            return 0
        fi
        if ((${#DISCOVERY_MATCHING_ADDRESSES[@]} == 1)); then
            DISCOVERED_TARGET="${DISCOVERY_MATCHING_ADDRESSES[0]}"
            cleanup_discovery
            return 0
        fi

        current_snapshot="$DISCOVERY_SNAPSHOT"
        if [[ "$previous_snapshot" != "$current_snapshot" ]]; then
            close_discovery_menu
            selected="$(<"$DISCOVERY_MENU_RESULT")"
            if target="$(selected_discovery_address "$selected")"; then
                DISCOVERED_TARGET="$target"
                cleanup_discovery
                return 0
            fi
            launch_discovery_menu
        fi
        sleep 1
    done
}

scan_for_new_device() {
    if command_is_available "$DMENU"; then
        scan_for_new_device_realtime "$@"
    else
        scan_for_new_device_blocking "$@"
    fi
}

new_device_menu_label() {
    local icon="$1"

    if command_is_available "$DMENU"; then
        printf '%s  Conectar novo dispositivo\n' "$icon"
    else
        printf '%s  Conectar novo dispositivo (%ss)\n' "$icon" "$SCAN_SECONDS"
    fi
}

rebind_device() {
    local address="$1"
    local label="$2"
    local original_name="${DEVICE_NAMES[$address]-$address}"

    # connect_device libera o lock do endereco antes de chamar esta funcao,
    # entao o endereco antigo pode ser protegido durante a remocao e liberado
    # antes de parear o novo endereco descoberto.
    if ! acquire_device_lock "$address" "$label"; then
        return 1
    fi
    notify_user 'Bluetooth' \
        "Atualizando o vínculo de $label. Coloque o dispositivo em modo de pareamento."
    bt_command 8 disconnect "$address" >/dev/null 2>&1 || true
    bt_command 8 remove "$address" >/dev/null 2>&1 || true
    release_device_lock

    # Um dispositivo LE pode ter um endereco diferente do vinculo BR/EDR.
    # A busca tenta primeiro o mesmo endereco, depois um unico nome igual e
    # somente entao pede uma selecao explicita no submenu de novos dispositivos.
    unset "DEVICE_PAIRED[$address]" "DEVICE_DISCOVERED[$address]" \
        "DEVICE_CONNECTED[$address]"
    if ! scan_for_new_device "$address" "$original_name"; then
        return 1
    fi
    pair_device "$DISCOVERED_TARGET" 0
}

report_simple_action() {
    local title="$1"
    local success_body="$2"
    local failure_body="$3"
    shift 3
    local output

    if output="$(bt_command 8 "$@")"; then
        notify_user "$title" "$success_body"
        log_event "$title: sucesso ($*)"
        refresh_status
        return 0
    fi
    log_event "$title: falha ($*): $output"
    notify_user "$title" "$failure_body Consulte $LOG_FILE."
    refresh_status
    return 1
}

confirm_forget() {
    local label="$1"
    local choice

    choice="$(menu_choice "Bluetooth > $label > Esquecer?" \
        'Confirmar esquecimento' 'Voltar')"
    case "$choice" in
        0) return 0 ;;
        1) return 2 ;;
        *) return 1 ;;
    esac
}

forget_device() {
    local address="$1"
    local label="$(device_label "$address")"
    local disconnect_output=""
    local remove_output=""

    local confirmation_status

    if confirm_forget "$label"; then
        confirmation_status=0
    else
        confirmation_status=$?
    fi
    case "$confirmation_status" in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac

    if ! acquire_device_lock "$address" "$label"; then
        return 3
    fi

    # Remove tambem encerra a conexao no BlueZ, mas desconectar explicitamente
    # torna o efeito previsivel e libera os perfis de audio antes da remocao.
    if [[ -n "${DEVICE_CONNECTED[$address]+present}" ]]; then
        disconnect_output="$(bt_command 8 disconnect "$address")" || true
        log_event "desconexão antes de esquecer $address: ${disconnect_output:-sucesso}"
    fi

    remove_output="$(bt_command 8 remove "$address")" || true
    if device_is_paired "$address"; then
        log_event "falha ao esquecer $address: ${remove_output:-vínculo ainda presente}"
        notify_user 'Falha ao esquecer dispositivo' \
            "$label continua pareado. Consulte $LOG_FILE."
        release_device_lock
        refresh_status
        return 1
    fi

    log_event "dispositivo esquecido: $address ($label); saída: ${remove_output:-sucesso}"
    notify_user 'Dispositivo esquecido' "$label foi removido do Bluetooth."
    release_device_lock
    refresh_status
    return 0
}

manage_device() {
    local address="$1"
    local label="$(device_label "$address")"
    local choice
    local action_label forget_status

    while :; do
        if [[ -n "${DEVICE_CONNECTED[$address]+present}" ]]; then
            action_label='Desconectar'
        else
            action_label='Conectar'
        fi

        choice="$(menu_choice "Bluetooth > $label" \
            "$action_label" 'Esquecer dispositivo' 'Voltar')"
        case "$choice" in
            0)
                if [[ "$action_label" == 'Desconectar' ]]; then
                    if acquire_device_lock "$address" "$label"; then
                        report_simple_action 'Bluetooth' 'Dispositivo desconectado.' \
                            'Não foi possível desconectar o dispositivo.' disconnect "$address" || true
                        release_device_lock
                    fi
                else
                    connect_device "$address" || true
                fi
                return 0
            ;;
            1)
                forget_status=0
                forget_device "$address" || forget_status=$?
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

pair_device() {
    local target="$1"
    local allow_rebind="${2:-1}"
    local label
    local pair_status

    if ! ensure_radio; then
        return 1
    fi

    # Uma corrida entre a descoberta e a selecao nao pode iniciar pareamento
    # de um dispositivo que ja foi pareado.
    if grep -Eq '^[[:space:]]*Paired:[[:space:]]+yes' <<<"$(device_info "$target")"; then
        connect_device "$target" "$allow_rebind"
        return $?
    fi

    label="${DEVICE_NAMES[$target]-$target}"
    notify_user 'Pareamento iniciado' \
        "Aguardando $label. Confirmações aparecerão em uma janela."
    if ! acquire_action_lock; then
        return 1
    fi
    if ! acquire_device_lock "$target" "$label"; then
        release_action_lock
        return 1
    fi
    pair_status=0
    pair_with_agent "$target" "$AGENT_TIMEOUT" || pair_status=$?
    if ((pair_status == 0)); then
        if wait_for_connection "$target"; then
            integrate_audio "$target" "$label" || true
            refresh_status
            release_device_lock
            release_action_lock
            return 0
        fi
        release_device_lock
        release_action_lock
        connect_device "$target" "$allow_rebind"
        return $?
    fi
    release_device_lock
    release_action_lock
    if ((pair_status == 2)); then
        notify_user 'Pareamento cancelado' "$label não foi pareado."
    else
        notify_user 'Falha no pareamento' \
            "$label não foi pareado. Consulte $LOG_FILE."
    fi
    return 1
}

connect_new_device() {
    if scan_for_new_device; then
        pair_device "$DISCOVERED_TARGET"
    fi
}

main_menu() {
# refresh=0 reutiliza as entradas ja carregadas ao voltar de um submenu.
local refresh="${1:-1}"
local controller_output radio_state paired_output connected_output
local choice kind value address name manage_status
local -a paired_addresses=()

if [[ "$refresh" == 1 ]]; then
MENU_LABELS=()
MENU_KINDS=()
MENU_VALUES=()
DEVICE_NAMES=()
DEVICE_PAIRED=()
DEVICE_DISCOVERED=()
DEVICE_CONNECTED=()
DEVICE_TRANSPORTS=()
NAME_COUNTS=()

controller_output="$(bt_batch 5 show)"
if ! grep -Eq '^[[:space:]]*Controller[[:space:]]+' <<<"$controller_output"; then
    add_entry '󰂲  Nenhum controlador Bluetooth' noop
else
    radio_state="$(awk -F': ' '/^[[:space:]]*Powered:/ {print tolower($2); exit}' \
        <<<"$controller_output")"
    if [[ "$radio_state" == yes ]]; then
        add_entry '󰂲 Desligar Bluetooth' radio-off
        add_entry "$(new_device_menu_label '󰂱')" discover

        paired_output="$(bt_batch 5 'devices Paired')"
        if ! grep -Eq '^[[:space:]]*Device[[:space:]]+' <<<"$paired_output"; then
            paired_output="$(bt_batch 5 paired-devices)"
        fi
        load_device_lines "$paired_output"
        for address in "${!DEVICE_DISCOVERED[@]}"; do
            DEVICE_PAIRED["$address"]=1
        done

        connected_output="$(bt_batch 5 'devices Connected')"
        load_connected_lines "$connected_output"

        # Algumas versoes antigas nao aceitam o filtro `devices Connected`.
        # Consulta somente os dispositivos pareados como fallback, sem abrir
        # uma sessao interativa.
        if ((${#DEVICE_CONNECTED[@]} == 0)); then
            for address in "${!DEVICE_PAIRED[@]}"; do
                if grep -Eq '^[[:space:]]*Connected:[[:space:]]+yes' \
                    <<<"$(device_info "$address")"; then
                    DEVICE_CONNECTED["$address"]=1
                fi
            done
        fi

        for address in "${!DEVICE_NAMES[@]}"; do
            name="${DEVICE_NAMES[$address]}"
            NAME_COUNTS["$name"]=$(( ${NAME_COUNTS[$name]:-0} + 1 ))
        done

        paired_addresses=()
        if ((${#DEVICE_PAIRED[@]} > 0)); then
            mapfile -t paired_addresses < <(printf '%s\n' "${!DEVICE_PAIRED[@]}" | sort)
        fi
        for address in "${paired_addresses[@]}"; do
            add_entry "󰂱  Gerenciar: $(device_label "$address")" manage "$address"
        done
    else
        add_entry '󰂯  Ativar Bluetooth' radio-on
    fi
fi
fi

choice="$(menu_choice 'Bluetooth' "${MENU_LABELS[@]}")"
[[ "$choice" =~ ^[0-9]+$ ]] || return 0
((choice < ${#MENU_KINDS[@]})) || return 0

kind="${MENU_KINDS[$choice]}"
value="${MENU_VALUES[$choice]}"

    case "$kind" in
    radio-off)
        if acquire_action_lock; then
            report_simple_action 'Bluetooth' 'Rádio desligado.' \
                'Não foi possível desligar o rádio.' power off || true
            release_action_lock
        fi
        ;;
    radio-on)
        if acquire_action_lock; then
            report_simple_action 'Bluetooth' 'Rádio ligado.' \
                'Não foi possível ligar o rádio.' power on || true
            release_action_lock
        fi
        ;;
    discover)
        connect_new_device || true
        ;;
    manage)
        if manage_device "$value"; then
            manage_status=0
        else
            manage_status=$?
        fi
        ((manage_status == 2)) && return 2
        ;;
    noop)
        ;;
esac
}

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
