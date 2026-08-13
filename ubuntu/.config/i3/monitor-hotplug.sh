#!/bin/bash

# Reconfigura as saídas RandR quando a topologia de monitores muda.
set -u
umask 077

XRANDR_BIN="${XRANDR_BIN:-xrandr}"
XDOTOOL_BIN="${XDOTOOL_BIN:-xdotool}"
FEH_BIN="${FEH_BIN:-feh}"
WALLPAPER="${WALLPAPER:-$HOME/.config/i3/dot-hands.jpg}"
POLL_INTERVAL="${MONITOR_HOTPLUG_POLL_INTERVAL:-1}"
MODE_WAIT_INTERVAL="${MONITOR_HOTPLUG_MODE_WAIT_INTERVAL:-0.5}"
MODE_WAIT_ATTEMPTS="${MONITOR_HOTPLUG_MODE_WAIT_ATTEMPTS:-12}"
POINTER_WAIT_INTERVAL="${MONITOR_HOTPLUG_POINTER_WAIT_INTERVAL:-0.1}"
POINTER_WAIT_ATTEMPTS="${MONITOR_HOTPLUG_POINTER_WAIT_ATTEMPTS:-10}"
if [[ -n "${XDG_RUNTIME_DIR:-}" ]]; then
    RUNTIME_DIR="$XDG_RUNTIME_DIR"
else
    RUNTIME_DIR="${TMPDIR:-/tmp}/monitor-hotplug-${UID:-$(id -u)}"
fi
LOCK_FILE="$RUNTIME_DIR/monitor-hotplug.lock"
BASE_FILE="$RUNTIME_DIR/monitor-hotplug-base"
LOG_FILE="$RUNTIME_DIR/monitor-hotplug.log"

mkdir -p "$RUNTIME_DIR" 2>/dev/null || exit 1

# Um reload do i3 pode iniciar uma nova cópia antes que a anterior termine.
# O descritor permanece aberto durante toda a vida do watcher.
exec 9>"$LOCK_FILE" || exit 1
flock -n 9 || exit 0

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

query_randr() {
    "$XRANDR_BIN" --query 2>/dev/null
}

connected_outputs() {
    awk '$2 == "connected" { print $1 }' <<<"$1" | sort -u
}

disconnected_outputs() {
    awk '$2 == "disconnected" { print $1 }' <<<"$1" | sort -u
}

output_has_mode() {
    local query="$1"
    local wanted="$2"

    awk -v wanted="$wanted" '
        $2 == "connected" { in_output = ($1 == wanted); next }
        in_output && $1 ~ /^[0-9]+x[0-9]+/ { found = 1 }
        END { exit(found ? 0 : 1) }
    ' <<<"$query"
}

output_has_preferred_mode() {
    local query="$1"
    local wanted="$2"

    awk -v wanted="$wanted" '
        $2 == "connected" { in_output = ($1 == wanted); next }
        in_output && $1 ~ /^[0-9]+x[0-9]+/ && index($0, "+") { found = 1 }
        END { exit(found ? 0 : 1) }
    ' <<<"$query"
}

output_is_active() {
    local query="$1"
    local wanted="$2"

    awk -v wanted="$wanted" '
        $2 == "connected" { in_output = ($1 == wanted); next }
        in_output && $1 ~ /^[0-9]+x[0-9]+/ && index($0, "*") { found = 1 }
        END { exit(found ? 0 : 1) }
    ' <<<"$query"
}

output_geometry() {
    local query="$1"
    local wanted="$2"

    awk -v wanted="$wanted" '
        $1 == wanted && $2 == "connected" {
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9]+x[0-9]+[-+][0-9]+[-+][0-9]+$/) {
                    print $i
                    exit
                }
            }
        }
    ' <<<"$query"
}

center_pointer_on_output() {
    local wanted="$1"
    local query
    local geometry
    local width
    local height
    local left
    local top
    local center_x
    local center_y
    local attempt

    for ((attempt = 1; attempt <= POINTER_WAIT_ATTEMPTS; attempt++)); do
        if ! query="$(query_randr)"; then
            sleep "$POINTER_WAIT_INTERVAL"
            continue
        fi

        geometry="$(output_geometry "$query" "$wanted")"
        if [[ "$geometry" =~ ^([0-9]+)x([0-9]+)([-+][0-9]+)([-+][0-9]+)$ ]]; then
            width="${BASH_REMATCH[1]}"
            height="${BASH_REMATCH[2]}"
            left="${BASH_REMATCH[3]}"
            top="${BASH_REMATCH[4]}"
            center_x=$((left + width / 2))
            center_y=$((top + height / 2))

            if "$XDOTOOL_BIN" mousemove --sync "$center_x" "$center_y" \
                >/dev/null 2>>"$LOG_FILE"; then
                return 0
            fi
        fi

        sleep "$POINTER_WAIT_INTERVAL"
    done

    log "falha ao centralizar o ponteiro na saída $wanted"
    return 1
}

snapshot_outputs() {
    connected_outputs "$1" | paste -sd, -
}

contains_output() {
    local wanted="$1"
    shift
    local output

    for output in "$@"; do
        [[ "$output" == "$wanted" ]] && return 0
    done
    return 1
}

choose_base() {
    local query="$1"
    shift
    local outputs=("$@")
    local stored_base=""
    local primary=""
    local output

    if [[ -s "$BASE_FILE" ]]; then
        IFS= read -r stored_base <"$BASE_FILE" || true
    fi
    if [[ -n "$stored_base" ]]; then
        printf '%s\n' "$stored_base"
        return 0
    fi

    primary="$(awk '$2 == "connected" && $3 == "primary" { print $1; exit }' <<<"$query")"
    if contains_output "$primary" "${outputs[@]}" \
        && output_is_active "$query" "$primary"; then
        printf '%s\n' "$primary" >"$BASE_FILE"
        printf '%s\n' "$primary"
        return 0
    fi

    for output in "${outputs[@]}"; do
        if output_is_active "$query" "$output"; then
            printf '%s\n' "$output" >"$BASE_FILE"
            printf '%s\n' "$output"
            return 0
        fi
    done

    if contains_output "$primary" "${outputs[@]}"; then
        printf '%s\n' "$primary" >"$BASE_FILE"
        printf '%s\n' "$primary"
        return 0
    fi

    printf '%s\n' "${outputs[0]}" >"$BASE_FILE"
    printf '%s\n' "${outputs[0]}"
}

refresh_wallpaper() {
    if ! "$FEH_BIN" --bg-fill "$WALLPAPER" >/dev/null 2>>"$LOG_FILE"; then
        log "falha ao atualizar o wallpaper"
    fi
}

apply_layout() {
    local query
    local output
    local base
    local previous
    local pointer_target
    local all_have_modes=false
    local attempt
    local outputs=()
    local externals=()
    local xrandr_args=()

    # A negociação EDID pode deixar a saída conectada sem anunciar modos por
    # alguns ciclos. Releia o estado até que todos os outputs estejam prontos.
    for ((attempt = 1; attempt <= MODE_WAIT_ATTEMPTS; attempt++)); do
        if ! query="$(query_randr)"; then
            log "falha ao consultar as saídas RandR (tentativa $attempt/$MODE_WAIT_ATTEMPTS)"
            sleep "$MODE_WAIT_INTERVAL"
            continue
        fi

        mapfile -t outputs < <(connected_outputs "$query")
        if ((${#outputs[@]} == 0)); then
            return 0
        fi

        all_have_modes=true
        for output in "${outputs[@]}"; do
            if ! output_has_mode "$query" "$output"; then
                all_have_modes=false
                break
            fi
        done
        if [[ "$all_have_modes" == true ]]; then
            break
        fi
        sleep "$MODE_WAIT_INTERVAL"
    done

    if [[ "$all_have_modes" != true ]]; then
        log "saídas conectadas sem modos anunciados após $MODE_WAIT_ATTEMPTS tentativas"
        return 1
    fi

    base="$(choose_base "$query" "${outputs[@]}")"
    if ! contains_output "$base" "${outputs[@]}"; then
        # Se o painel-base original foi removido, use temporariamente a saída
        # conectada mais estável. O valor persistido permite restaurá-lo quando
        # ele voltar, sem depender do nome de qualquer conector.
        base="${outputs[0]}"
    fi

    for output in "${outputs[@]}"; do
        [[ "$output" == "$base" ]] || externals+=("$output")
    done

    # O --preferred é usado quando o EDID marcou um modo recomendado. Saídas
    # sem esse marcador usam --auto, que é o fallback suportado pelo RandR.
    previous="$base"
    for output in "${outputs[@]}"; do
        xrandr_args+=(--output "$output")
        if output_has_preferred_mode "$query" "$output"; then
            xrandr_args+=(--preferred)
        else
            xrandr_args+=(--auto)
        fi

        if [[ "$output" == "$base" ]]; then
            xrandr_args+=(--pos 0x0)
            if ((${#externals[@]} == 0)); then
                xrandr_args+=(--primary)
            fi
        elif [[ "$previous" == "$base" ]]; then
            xrandr_args+=(--primary --left-of "$previous")
            previous="$output"
        else
            xrandr_args+=(--left-of "$previous")
            previous="$output"
        fi
    done

    # Desliga saídas desconectadas para não deixar CRTC/monitor RandR órfão
    # (fantasma), que faz o i3lock desenhar um indicador por monitor fantasma.
    mapfile -t disconnected < <(disconnected_outputs "$query")
    for output in "${disconnected[@]}"; do
        xrandr_args+=(--output "$output" --off)
    done

    if ! "$XRANDR_BIN" "${xrandr_args[@]}" >/dev/null 2>>"$LOG_FILE"; then
        log "falha ao aplicar o layout; a tentativa será repetida"
        return 1
    fi

    if ((${#externals[@]} > 0)); then
        pointer_target="${externals[0]}"
    else
        pointer_target="$base"
    fi
    if ! center_pointer_on_output "$pointer_target"; then
        log "layout aplicado, mas o ponteiro não foi reposicionado"
    fi

    # Redesenha o wallpaper no novo tamanho do root window; sem isso, a imagem
    # ficaria no tamanho antigo até um restart do i3.
    refresh_wallpaper

    return 0
}

last_snapshot=""
initialized=false
pending=true
last_failure=""

while :; do
    if ! current_query="$(query_randr)"; then
        if [[ "$last_failure" != query ]]; then
            log "falha ao consultar o estado RandR; aguardando nova tentativa"
            last_failure=query
        fi
        pending=true
        sleep "$POLL_INTERVAL"
        continue
    fi

    current_snapshot="$(snapshot_outputs "$current_query")"
    if [[ "$initialized" != true || "$current_snapshot" != "$last_snapshot" || "$pending" == true ]]; then
        if apply_layout; then
            last_snapshot="$current_snapshot"
            initialized=true
            pending=false
            last_failure=""
        else
            pending=true
            if [[ "$last_failure" != apply ]]; then
                log "layout pendente; aguardando estabilização das saídas"
                last_failure=apply
            fi
        fi
    fi

    sleep "$POLL_INTERVAL"
done
