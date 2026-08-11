#!/usr/bin/env bash

# Menu Bluetooth para i3status: dmenu no X11 (com fallback para Walker) e
# bluetoothctl como backend. Os fluxos sao lineares e previsiveis:
# - conectar nunca pareia e nunca abre um terminal;
# - parear usa um agente em segundo plano e prompts graficos;
# - um vinculo rejeitado so e removido por uma acao explicita de reparo.
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

SCAN_SECONDS="${BLUETOOTH_SCAN_SECONDS:-15}"
PAIR_SCAN_SECONDS="${BLUETOOTH_PAIR_SCAN_SECONDS:-30}"
CONNECT_TIMEOUT="${BLUETOOTH_CONNECT_TIMEOUT:-12}"
CONNECT_SETTLE_SECONDS="${BLUETOOTH_CONNECT_SETTLE_SECONDS:-15}"
AGENT_TIMEOUT="${BLUETOOTH_AGENT_TIMEOUT:-45}"
AUDIO_WAIT_SECONDS="${BLUETOOTH_AUDIO_WAIT_SECONDS:-12}"

for variable_name in \
    SCAN_SECONDS PAIR_SCAN_SECONDS CONNECT_TIMEOUT CONNECT_SETTLE_SECONDS \
    AGENT_TIMEOUT AUDIO_WAIT_SECONDS; do
    if [[ ! "${!variable_name}" =~ ^[0-9]+$ ]]; then
        case "$variable_name" in
            SCAN_SECONDS) SCAN_SECONDS=15 ;;
            PAIR_SCAN_SECONDS) PAIR_SCAN_SECONDS=30 ;;
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
REPAIR_PREFIX="$STATE_DIR/bluetooth-repair"

# Impede conexoes, pareamentos e reparos concorrentes. A acao mantem o lock
# ate terminar; a acao scan fecha o descritor antes de reabrir o menu.
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/bluetooth-menu-$(id -u).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

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

# Sessao curta usada apenas para consultas e comandos que nao exigem agente.
bt_batch() {
    local timeout_seconds="$1"
    shift

    {
        printf '%s\n' "$@"
        printf 'quit\n'
    } | timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
        "$BLUETOOTHCTL" 2>/dev/null || true
}

bt_command() {
    local timeout_seconds="$1"
    shift

    timeout --signal=TERM --kill-after=2 "$timeout_seconds" \
        "$BLUETOOTHCTL" "$@" 2>&1
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

mark_repair_needed() {
    local address="$1"

    : >"$REPAIR_PREFIX-$address" 2>/dev/null || true
}

clear_repair_needed() {
    local address="$1"

    rm -f -- "$REPAIR_PREFIX-$address" 2>/dev/null || true
}

repair_is_recent() {
    local address="$1"
    local marker="$REPAIR_PREFIX-$address"
    local now mtime age

    [[ -f "$marker" ]] || return 1
    now="$(date +%s 2>/dev/null || true)"
    mtime="$(stat -c '%Y' "$marker" 2>/dev/null || true)"
    [[ "$now" =~ ^[0-9]+$ && "$mtime" =~ ^[0-9]+$ ]] || return 1
    age=$((now - mtime))
    ((age >= 0 && age < 300))
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
# A funcao retorna o indice selecionado; cancelar retorna uma linha vazia.
menu_choice() {
    local prompt="$1"
    shift
    local labels=("$@")
    local selected="" choice="" lines
    local index

    lines=$(( ${#labels[@]} < 12 ? ${#labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    if command_is_available "$DMENU"; then
        selected="$(printf '%s\n' "${labels[@]}" \
            | "$DMENU" -i -l "$lines" -p "$prompt" \
                -fn 'JetBrainsMono Nerd Font:size=10' \
                -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000')" || true
        for index in "${!labels[@]}"; do
            if [[ "${labels[$index]}" == "$selected" ]]; then
                choice="$index"
                break
            fi
        done
    elif command_is_available "$WALKER"; then
        choice="$(printf '%s\n' "${labels[@]}" \
            | "$WALKER" --dmenu --index --exit --theme vantablack \
                --width 644 --height 570 --placeholder "$prompt")" || true
    fi
    printf '%s\n' "$choice"
}

agent_confirm() {
    local prompt="$1"
    local choice

    choice="$(menu_choice "$prompt" 'Confirmar' 'Cancelar')"
    case "$choice" in
        0) printf 'yes\n' ;;
        *) printf 'cancel\n' ;;
    esac
}

agent_pin() {
    local prompt="$1"
    local selected=""

    # dmenu permite escolher 0000 ou digitar outro valor. Walker, usado como
    # fallback, oferece a opcao comum sem inventar um PIN para o dispositivo.
    if command_is_available "$DMENU"; then
        selected="$(printf '%s\n' '0000' 'Cancelar' \
            | "$DMENU" -i -l 2 -p "$prompt" \
                -fn 'JetBrainsMono Nerd Font:size=10' \
                -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000')" || true
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

# Pareia em segundo plano com um agente residente. A saida do bluetoothctl e
# consumida aqui para responder prompts sem abrir um terminal. Retorna 0 quando
# a conexao foi estabelecida, 2 quando o usuario cancelou e 1 em falha.
pair_with_agent() {
    local target="$1"
    local timeout_seconds="$2"
    local bt_in="" bt_out="" bt_pid="" byte buffer=""
    local result="" answer="" passkey=""
    local deadline waited
    local trust_sent=0 failed_pending=0

    if ! ensure_radio; then
        return 1
    fi

    coproc BTAGENT { "$BLUETOOTHCTL" 2>&1; }
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

            if [[ "$buffer" == *"Request PIN code"* \
                || "$buffer" == *"Enter PIN code"* ]]; then
                answer="$(agent_pin "PIN do Bluetooth para $target")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$buffer" == *"Confirm passkey"* ]]; then
                passkey=""
                if [[ "$buffer" =~ [Pp]asskey[[:space:]]+([0-9]{1,6}) ]]; then
                    passkey="${BASH_REMATCH[1]}"
                fi
                answer="$(agent_confirm \
                    "Confirme a passkey ${passkey:-mostrada no dispositivo}")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$buffer" == *"Enter passkey"* ]]; then
                answer="$(agent_pin 'Digite a passkey exibida no dispositivo')"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$buffer" == *"Authorize"* ]]; then
                answer="$(agent_confirm "Autorizar o dispositivo $target?")"
                if [[ "$answer" == cancel ]]; then
                    printf 'cancel-pairing\n' >&"$bt_in" 2>/dev/null || true
                    result="cancelled"
                else
                    printf '%s\n' "$answer" >&"$bt_in" 2>/dev/null || true
                fi
                buffer=""
            elif [[ "$buffer" == *"Pairing successful"* ]]; then
                if ((trust_sent == 0)); then
                    printf 'trust %s\nconnect %s\n' "$target" "$target" \
                        >&"$bt_in" 2>/dev/null || true
                    trust_sent=1
                fi
                buffer=""
            elif [[ "$buffer" == *"AlreadyExists"* ]]; then
                # Corrida ou estado antigo: se ja existe, o proximo passo e
                # conectar, nunca abrir outro fluxo de pareamento.
                if ((trust_sent == 0)); then
                    printf 'trust %s\nconnect %s\n' "$target" "$target" \
                        >&"$bt_in" 2>/dev/null || true
                    trust_sent=1
                fi
                failed_pending=0
                buffer=""
            elif [[ "$buffer" == *"Connection successful"* ]]; then
                result="connected"
                buffer=""
            elif [[ "$buffer" == *"AuthenticationFailed"* \
                || "$buffer" == *"Failed to connect"* \
                || "$buffer" == *"No agent available"* \
                || "$buffer" == *"Canceled"* ]]; then
                result="failed"
                buffer=""
            elif [[ "$buffer" == *"Failed to pair"* ]]; then
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
    exec {bt_in}>&- 2>/dev/null || true
    exec {bt_out}>&- 2>/dev/null || true

    waited=0
    while kill -0 "$bt_pid" 2>/dev/null && ((waited < 10)); do
        sleep 0.5
        waited=$((waited + 1))
    done
    kill "$bt_pid" 2>/dev/null || true
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
            clear_repair_needed "$address"
            notify_user 'Bluetooth conectado' "$label.$body"
            audio_refresh_status
            return 0
        fi
        sleep 1
    done

    device_details="$(device_info "$address")"
    if ! grep -Eqi 'UUID: (Audio Sink|Audio Source|Headset|Handsfree|Audio Stream Control|Published Audio)' \
        <<<"$device_details"; then
        notify_user 'Bluetooth sem perfil de áudio' \
            "$label está conectado somente por BLE. Coloque-o em modo de pareamento e use Reparar vínculo existente."
    else
        notify_user 'Bluetooth conectado' \
            "$label conectou, mas a saída de áudio Bluetooth não foi criada."
    fi
    log_event "sem sink Bluetooth para $address ($label)"
    audio_refresh_status
    return 1
}

connect_device() {
    local address="$1"
    local label="${DEVICE_NAMES[$address]-$address}"
    local output="" last_error=""
    local attempt auth_failure=0

    if ! ensure_radio; then
        return 1
    fi

    # Conectar nao chama pair. O trust e idempotente e so e aplicado a um
    # dispositivo que ja foi selecionado pelo usuario no menu.
    bt_command 5 trust "$address" >/dev/null 2>&1 || true
    for ((attempt = 1; attempt <= 2; attempt++)); do
        if output="$(bt_command "$CONNECT_TIMEOUT" connect "$address")" \
            && wait_for_connection "$address"; then
            log_event "conectado: $address ($label), tentativa $attempt"
            refresh_status
            integrate_audio "$address" "$label" || true
            return 0
        fi
        last_error="$(connection_error_summary "$output")"
        if grep -Eiq 'authenticat|not.?authori|bond|key' <<<"$output"; then
            auth_failure=1
        fi
        log_event "tentativa $attempt falhou para $address ($label): $last_error"
        ((attempt < 2)) && sleep 1
    done

    # Uma falha repetida em um dispositivo pareado pode indicar chaves antigas.
    # Apenas marca uma acao de reparo; a remocao do vinculo nunca e silenciosa.
    mark_repair_needed "$address"
    if ((auth_failure == 1)); then
        notify_user 'Vínculo Bluetooth inválido' \
            "$label não autenticou. Abra o menu e escolha 'Reparar vínculo'."
    else
        notify_user 'Falha ao conectar Bluetooth' \
            "$label não estabilizou. Se necessário, escolha 'Reparar vínculo'."
    fi
    return 1
}

run_scan() {
    local output=""

    if ! ensure_radio; then
        return 1
    fi
    notify_user 'Bluetooth' "Procurando dispositivos por ${SCAN_SECONDS}s."
    output="$({
        printf 'scan on\n'
        sleep "$SCAN_SECONDS"
        printf 'scan off\nquit\n'
    } | timeout --signal=TERM --kill-after=2 "$((SCAN_SECONDS + 5))" \
        "$BLUETOOTHCTL" 2>&1)" || true
    log_event "busca concluída: ${output:-sem saída}"
    notify_user 'Bluetooth' 'Busca concluída. A lista será atualizada.'
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

pair_device() {
    local target="${1:-}"
    local discovery="" row address name choice label transport
    local labels=() addresses=()
    local pair_status

    if ! ensure_radio; then
        return 1
    fi

    if [[ -z "$target" ]]; then
        notify_user 'Bluetooth' \
            "Procurando dispositivos por ${SCAN_SECONDS}s para parear."
        discovery="$({
            printf 'scan on\n'
            sleep "$SCAN_SECONDS"
            printf 'scan off\nquit\n'
        } | timeout --signal=TERM --kill-after=2 "$((SCAN_SECONDS + 5))" \
            "$BLUETOOTHCTL" 2>&1)" || true
        log_event "busca para pareamento concluída: ${discovery:-sem saída}"
        load_transport_lines "$discovery"
        discovery="$(bt_batch 6 devices)"
        while IFS= read -r row; do
            if [[ "$row" =~ ^[[:space:]]*Device[[:space:]]+([[:xdigit:]:]{17})([[:space:]]+(.*))?$ ]]; then
                address="${BASH_REMATCH[1]}"
                name="${BASH_REMATCH[3]-}"
                name="${name##+([[:space:]])}"
                name="${name%%+([[:space:]])}"
                [[ -n "${DEVICE_PAIRED[$address]+present}" ]] && continue
                transport="${DEVICE_TRANSPORTS[$address]-unknown}"
                labels+=("${name:-$address} [$transport] · $address")
                addresses+=("$address")
                DEVICE_NAMES["$address"]="${name:-$address}"
            fi
        done <<<"$discovery"

        if ((${#addresses[@]} == 0)); then
            notify_user 'Pareamento' 'Nenhum dispositivo não pareado foi encontrado.'
            return 1
        fi
        choice="$(menu_choice 'Parear dispositivo' "${labels[@]}")"
        if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice >= ${#addresses[@]})); then
            return 1
        fi
        target="${addresses[$choice]}"
    fi

    # Uma corrida entre a descoberta e a selecao nao pode iniciar pareamento
    # de um dispositivo que ja foi pareado.
    if grep -Eq '^[[:space:]]*Paired:[[:space:]]+yes' <<<"$(device_info "$target")"; then
        connect_device "$target"
        return $?
    fi

    label="${DEVICE_NAMES[$target]-$target}"
    notify_user 'Pareamento iniciado' \
        "Aguardando $label. Confirmações aparecerão em uma janela."
    pair_status=0
    pair_with_agent "$target" "$AGENT_TIMEOUT" || pair_status=$?
    if ((pair_status == 0)); then
        if wait_for_connection "$target"; then
            clear_repair_needed "$target"
            integrate_audio "$target" "$label" || true
            refresh_status
            return 0
        fi
        connect_device "$target"
        return $?
    fi
    if ((pair_status == 2)); then
        notify_user 'Pareamento cancelado' "$label não foi pareado."
    else
        notify_user 'Falha no pareamento' \
            "$label não foi pareado. Consulte $LOG_FILE."
    fi
    return 1
}

repair_device() {
    local address="$1"
    local label="${DEVICE_NAMES[$address]-$address}"
    local choice

    choice="$(menu_choice "Reparar $label" 'Continuar' 'Cancelar')"
    [[ "$choice" == 0 ]] || return 0

    notify_user 'Reparando vínculo Bluetooth' \
        "Coloque $label fora do estojo e em modo de pareamento."
    bt_command 8 disconnect "$address" >/dev/null 2>&1 || true
    bt_command 8 remove "$address" >/dev/null 2>&1 || true
    clear_repair_needed "$address"

    # Um dispositivo LE pode ter um endereco diferente do vinculo BR/EDR
    # usado pelo A2DP. Depois de remover o vinculo antigo, a nova varredura
    # permite selecionar o endereco de audio anunciado pelo fone.
    unset "DEVICE_PAIRED[$address]" "DEVICE_DISCOVERED[$address]" \
        "DEVICE_CONNECTED[$address]"
    pair_device
}

repair_paired_device() {
    local address choice
    local labels=() addresses=() paired_addresses=()

    if ((${#DEVICE_PAIRED[@]} > 0)); then
        mapfile -t paired_addresses < <(printf '%s\n' \
            "${!DEVICE_PAIRED[@]}" | sort)
    fi
    for address in "${paired_addresses[@]}"; do
        labels+=("$(device_label "$address")")
        addresses+=("$address")
    done
    labels+=("Cancelar")

    choice="$(menu_choice 'Reparar vínculo' "${labels[@]}")"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((choice >= ${#addresses[@]})); then
        return 0
    fi
    repair_device "${addresses[$choice]}"
}

controller_output="$(bt_batch 5 show)"
if ! grep -Eq '^[[:space:]]*Controller[[:space:]]+' <<<"$controller_output"; then
    add_entry '󰂲  Nenhum controlador Bluetooth' noop
else
    radio_state="$(awk -F': ' '/^[[:space:]]*Powered:/ {print tolower($2); exit}' \
        <<<"$controller_output")"
    if [[ "$radio_state" == yes ]]; then
        add_entry '󰂯  Desligar Bluetooth' radio-off
        add_entry "󰤨  Procurar dispositivos (${SCAN_SECONDS}s)" scan
        add_entry '󰂱  Parear novo dispositivo' pair

        paired_output="$(bt_batch 5 'devices Paired')"
        if ! grep -Eq '^[[:space:]]*Device[[:space:]]+' <<<"$paired_output"; then
            paired_output="$(bt_batch 5 paired-devices)"
        fi
        load_device_lines "$paired_output"
        for address in "${!DEVICE_DISCOVERED[@]}"; do
            DEVICE_PAIRED["$address"]=1
        done
        if ((${#DEVICE_PAIRED[@]} > 0)); then
            add_entry '󰂰  Reparar vínculo existente' repair-menu
        fi

        discovered_output="$(bt_batch 5 devices)"
        load_device_lines "$discovered_output"
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
            if [[ -n "${DEVICE_CONNECTED[$address]+present}" ]]; then
                add_entry "󰂱  Desconectar: $(device_label "$address")" disconnect "$address"
            else
                add_entry "󰂯  Conectar: $(device_label "$address")" connect "$address"
                if repair_is_recent "$address"; then
                    add_entry "󰂰  Reparar vínculo: $(device_label "$address")" repair "$address"
                fi
            fi
        done

        discovered_addresses=()
        if ((${#DEVICE_DISCOVERED[@]} > 0)); then
            mapfile -t discovered_addresses < <(printf '%s\n' \
                "${!DEVICE_DISCOVERED[@]}" | sort)
        fi
        for address in "${discovered_addresses[@]}"; do
            [[ -n "${DEVICE_PAIRED[$address]+present}" ]] && continue
            add_entry "󰂯  Parear: $(device_label "$address")" pair "$address"
        done
    else
        add_entry '󰂯  Ativar Bluetooth' radio-on
        add_entry '󰂱  Parear novo dispositivo' pair
    fi
fi

choice="$(menu_choice 'Bluetooth' "${MENU_LABELS[@]}")"
[[ "$choice" =~ ^[0-9]+$ ]] || exit 0
((choice < ${#MENU_KINDS[@]})) || exit 0

kind="${MENU_KINDS[$choice]}"
value="${MENU_VALUES[$choice]}"

case "$kind" in
    radio-off)
        report_simple_action 'Bluetooth' 'Rádio desligado.' \
            'Não foi possível desligar o rádio.' power off || true
        ;;
    radio-on)
        report_simple_action 'Bluetooth' 'Rádio ligado.' \
            'Não foi possível ligar o rádio.' power on || true
        ;;
    scan)
        run_scan || true
        exec 9>&-
        exec "$0"
        ;;
    connect)
        connect_device "$value" || true
        ;;
    disconnect)
        report_simple_action 'Bluetooth' 'Dispositivo desconectado.' \
            'Não foi possível desconectar o dispositivo.' disconnect "$value" || true
        ;;
    pair)
        pair_device "$value" || true
        ;;
    repair)
        repair_device "$value" || true
        ;;
    repair-menu)
        repair_paired_device || true
        ;;
    noop)
        ;;
esac
