#!/usr/bin/env bash

# Menu de audio do i3status: troca a saida (sink) e a entrada (source) de
# audio via pactl (PulseAudio/pipewire-pulse) ou wpctl (PipeWire nativo),
# usando dmenu no X11 (com fallback para Walker). O fluxo e linear:
# categoria -> dispositivo -> porta (somente quando necessario) -> aplicacao
# com confirmacao e notificacao do resultado. Nenhum nome de hardware e
# assumido; os alvos sao nomes/IDs reportados pelo servidor de audio.
set -Eeuo pipefail

export LC_ALL=C

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=audio-lib.sh
. "$SCRIPT_DIR/audio-lib.sh"

DMENU="${AUDIO_MENU_BIN:-${DMENU_BIN:-/usr/bin/dmenu}}"
WALKER="${WALKER_BIN:-$HOME/.local/bin/walker}"

if ! audio_have_cmd "$DMENU" && ! audio_have_cmd "$WALKER"; then
    exit 0
fi

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/ubuntu-i3"
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    STATE_DIR="${XDG_RUNTIME_DIR:-/tmp}"
fi
LOG_FILE="$STATE_DIR/audio.log"

log_event() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE" 2>/dev/null || true
}

# Evita que cliques repetidos abram varios menus ou troquem a saida ao mesmo
# tempo. O descritor e fechado antes das acoes para nao bloquear o proximo
# clique.
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/audio-menu-$(id -u).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

AUDIO_ICON="󰓃"
AUDIO_PORT_ICON="󰓅"
INPUT_ICON="󰍬"
INPUT_PORT_ICON="󰝏"
CURRENT_SUFFIX=" · atual"
CANCEL_LABEL="Cancelar"

MENU_LABELS=()
MENU_KINDS=()
MENU_VALUES=()

add_entry() {
    MENU_LABELS+=("$1")
    MENU_KINDS+=("$2")
    MENU_VALUES+=("${3:-}")
}

# Exibe um menu dmenu (com fallback para Walker) e imprime o indice escolhido.
# Cancelamento e indisponibilidade do launcher resultam em saida vazia.
menu_choice() {
    local prompt="$1"
    shift
    local labels=("$@")
    local selected="" choice="" lines
    local i

    lines=$(( ${#labels[@]} < 12 ? ${#labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    if [[ -x "$DMENU" ]]; then
        selected="$(printf '%s\n' "${labels[@]}" \
            | "$DMENU" -i -l "$lines" -p "$prompt" \
                -fn 'JetBrainsMono Nerd Font:size=12' \
                -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000')" || true
        for i in "${!labels[@]}"; do
            if [[ "${labels[$i]}" == "$selected" ]]; then
                choice="$i"
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

backend="$(audio_backend)"
if [[ "$backend" == none ]]; then
    add_entry "Nenhum servidor de audio ativo" noop
    add_entry "$CANCEL_LABEL" noop
    menu_choice "Audio" "${MENU_LABELS[@]}" >/dev/null
    exit 0
fi

# Etapa 1: categoria. Quando um perfil Bluetooth foi ativado, o menu volta
# diretamente para a direcao escolhida para que o fluxo continue linear.
direction="${AUDIO_MENU_DIRECTION:-}"
if [[ "$direction" != sink && "$direction" != source ]]; then
    add_entry "$AUDIO_ICON  Saída de áudio" category sink
    add_entry "$INPUT_ICON  Entrada de áudio" category source
    add_entry "$CANCEL_LABEL" noop
    choice="$(menu_choice "Audio" "${MENU_LABELS[@]}")"
    [[ "$choice" =~ ^[0-9]+$ ]] || exit 0
    kind="${MENU_KINDS[$choice]}"
    direction="${MENU_VALUES[$choice]}"
    [[ "$kind" == category ]] || exit 0
fi

icon="$AUDIO_ICON"
port_icon="$AUDIO_PORT_ICON"
[[ "$direction" == source ]] && { icon="$INPUT_ICON"; port_icon="$INPUT_PORT_ICON"; }

# Etapa 2: lista de dispositivos.
declare -A DEVICE_NAMES=()
declare -A DEVICE_DESCS=()
declare -A DEVICE_ACTIVE_PORTS=()
declare -A DEVICE_PORTS=()
declare -A NAME_TO_TOKEN=()

MENU_LABELS=()
MENU_KINDS=()
MENU_VALUES=()
device_count=0
while IFS=$'\t' read -r token name description active_port ports; do
    [[ -n "$token" ]] || continue
    device_count=$((device_count + 1))
    DEVICE_NAMES["$token"]="$name"
    DEVICE_DESCS["$token"]="$description"
    DEVICE_ACTIVE_PORTS["$token"]="$active_port"
    DEVICE_PORTS["$token"]="$ports"
    NAME_TO_TOKEN["$name"]="$token"

    label="$description"
    if [[ "$direction" == source && "$name" == *.monitor ]]; then
        label="Monitor de $description"
    fi
    add_entry "$icon  $label" device "$token"
done < <(audio_list "$direction")

# Perfis HFP/HSP e BAP podem fornecer a direcao solicitada sem que o node
# correspondente esteja ativo ainda. Eles aparecem como uma acao explicita;
# ao seleciona-la, o menu ativa o perfil e volta diretamente para a mesma
# categoria para listar os nodes criados pelo servidor.
PROFILE_LABELS=()
PROFILE_VALUES=()
while IFS=$'\t' read -r card card_description profile profile_description active; do
    [[ -n "$card" && -n "$profile" ]] || continue
    [[ "$active" == yes ]] && continue
    label="${profile_description:-$profile}"
    if [[ -n "$card_description" ]]; then
        label="$label · $card_description"
    fi
    PROFILE_LABELS+=("$label")
    profile_value="${card}"$'\t'"${profile}"
    PROFILE_VALUES+=("$profile_value")
    add_entry "$icon  Ativar perfil: $label" profile "$profile_value"
done < <(audio_list_profile_options "$direction")

current_token="$(audio_default "$direction")"
if [[ -z "$current_token" && "$backend" == pipewire ]]; then
    configured="$(audio_wpctl_configured "$direction")"
    if [[ -n "$configured" ]]; then
        current_token="${NAME_TO_TOKEN[$configured]-}"
    fi
fi
for i in "${!MENU_VALUES[@]}"; do
    if [[ "${MENU_VALUES[$i]}" == "$current_token" ]]; then
        MENU_LABELS[$i]="${MENU_LABELS[$i]}$CURRENT_SUFFIX"
    fi
done

# Desambiguacao: dispositivos com a mesma descricao recebem o node.name.
declare -A DESC_COUNTS=()
for token in "${!DEVICE_DESCS[@]}"; do
    desc="${DEVICE_DESCS[$token]}"
    DESC_COUNTS["$desc"]=$(( ${DESC_COUNTS["$desc"]:-0} + 1 ))
done
for i in "${!MENU_VALUES[@]}"; do
    [[ "${MENU_KINDS[$i]}" == device ]] || continue
    token="${MENU_VALUES[$i]}"
    desc="${DEVICE_DESCS[$token]}"
    if (( ${DESC_COUNTS["$desc"]:-0} > 1 )); then
        MENU_LABELS[$i]="${MENU_LABELS[$i]} · ${DEVICE_NAMES[$token]}"
    fi
done

if ((device_count == 0 && ${#PROFILE_LABELS[@]} == 0)); then
    add_entry "Nenhum dispositivo de audio disponível" noop
    add_entry "$CANCEL_LABEL" noop
    menu_choice "Audio" "${MENU_LABELS[@]}" >/dev/null
    exit 0
fi

choice="$(menu_choice "$( [[ "$direction" == sink ]] && printf 'Saída de áudio' || printf 'Entrada de áudio' )" "${MENU_LABELS[@]}")"
[[ "$choice" =~ ^[0-9]+$ ]] || exit 0
kind="${MENU_KINDS[$choice]}"
token="${MENU_VALUES[$choice]}"

if [[ "$kind" == profile ]]; then
    IFS=$'\t' read -r profile_card profile_name <<<"$token"
    if ! output="$(audio_set_profile "$profile_card" "$profile_name" 2>&1)"; then
        log_event "falha: set-profile $profile_card $profile_name: ${output:-sem saida}"
        audio_notify "Áudio" \
            "Não foi possível ativar o perfil de áudio. Consulte $LOG_FILE."
        exit 1
    fi
    log_event "perfil aplicado: $profile_card $profile_name"
    audio_notify "Áudio" 'Perfil Bluetooth ativado; atualizando dispositivos.'
    audio_refresh_status
    exec 9>&-
    sleep 1
    exec env AUDIO_MENU_DIRECTION="$direction" "$0"
fi

[[ "$kind" == device ]] || exit 0

# Etapa 3: porta, somente quando ha mais de uma opcao real disponivel.
PORT_LABELS=()
PORT_VALUES=()
ports_field="${DEVICE_PORTS[$token]-}"
if [[ -n "$ports_field" ]]; then
    while IFS=$'\t' read -r port_name port_desc avail; do
        [[ -n "$port_name" ]] || continue
        [[ "$avail" == no ]] && continue
        PORT_LABELS+=("$port_desc")
        PORT_VALUES+=("$port_name")
    done <<<"${ports_field//$'\034'/$'\n'}"
fi

port_choice=""
if ((${#PORT_VALUES[@]} > 1)); then
    MENU_LABELS=()
    MENU_KINDS=()
    MENU_VALUES=()
    active_port="${DEVICE_ACTIVE_PORTS[$token]-}"
    for i in "${!PORT_VALUES[@]}"; do
        label="${PORT_LABELS[$i]}"
        if [[ -n "$active_port" && "${PORT_VALUES[$i]}" == "$active_port" ]]; then
            label="$label$CURRENT_SUFFIX"
        fi
        add_entry "$port_icon  $label" port "${PORT_VALUES[$i]}"
    done
    add_entry "$CANCEL_LABEL" noop
    choice="$(menu_choice "Porta" "${MENU_LABELS[@]}")"
    [[ "$choice" =~ ^[0-9]+$ ]] || exit 0
    kind="${MENU_KINDS[$choice]}"
    port_choice="${MENU_VALUES[$choice]}"
    [[ "$kind" == port ]] || exit 0
elif ((${#PORT_VALUES[@]} == 1)); then
    port_choice="${PORT_VALUES[0]}"
fi

# Nao manter o lock aberto nos comandos iniciados pela acao escolhida.
exec 9>&-

description="${DEVICE_DESCS[$token]-$token}"
kind_label="saída de áudio"
[[ "$direction" == source ]] && kind_label="entrada de áudio"

# Etapa 4: aplicar e confirmar.
if ! output="$(audio_set_default "$direction" "$token" 2>&1)"; then
    log_event "falha: set-default $direction $token: ${output:-sem saida}"
    audio_notify "Áudio" "Não foi possível alterar a $kind_label para $description. Consulte $LOG_FILE."
    exit 1
fi
log_event "default aplicado: $direction $token"

if [[ -n "$port_choice" ]]; then
    if ! output="$(audio_set_port "$direction" "$token" "$port_choice" 2>&1)"; then
        log_event "falha na porta: $direction $token $port_choice: ${output:-sem saida}"
        audio_notify "Áudio" "Dispositivo alterado, mas a porta não pôde ser aplicada."
    else
        log_event "porta aplicada: $direction $token $port_choice"
    fi
fi

moved="$(audio_move_streams "$direction" "$token")"
if audio_default_is "$direction" "$token"; then
    extra=""
    if [[ "$moved" =~ ^[0-9]+$ && "$moved" -gt 0 ]]; then
        extra=" ($moved aplicações em execução movidas)"
    fi
    audio_notify "Áudio" "$kind_label alterada para: $description$extra"
    log_event "sucesso: $direction $token"
else
    audio_notify "Áudio" "A $kind_label não foi confirmada para $description. Consulte $LOG_FILE."
    log_event "falha na confirmacao: $direction $token"
fi
audio_refresh_status
