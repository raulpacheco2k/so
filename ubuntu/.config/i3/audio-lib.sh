#!/usr/bin/env bash

# Camada comum de controle de audio usada pelo audio-menu.sh, pelo vol.sh e
# pelo filtro do i3status. Detecta o backend em tempo de execucao:
# - pactl: PulseAudio classico ou PipeWire com pipewire-pulse;
# - wpctl: PipeWire nativo (sem servidor de compatibilidade PulseAudio).
# Nenhum nome de hardware e assumido; os alvos sao nomes/IDs reportados pelo
# proprio servidor, portanto o comportamento nao depende da arquitetura.
#
# Este arquivo deve ser carregado com `source` e nao executa nada sozinho.

export LC_ALL=C

AUDIO_PACTL="${AUDIO_PACTL_BIN:-pactl}"
AUDIO_WPCTL="${AUDIO_WPCTL_BIN:-wpctl}"
AUDIO_PWDUMP="${AUDIO_PWDUMP_BIN:-pw-dump}"
AUDIO_JQ="${AUDIO_JQ_BIN:-jq}"
AUDIO_PKILL="${AUDIO_PKILL_BIN:-/usr/bin/pkill}"
AUDIO_NOTIFY="${AUDIO_NOTIFY_BIN:-notify-send}"
AUDIO_BACKEND_DETECTED=""

audio_have_cmd() {
    local command_name="$1"

    if [[ "$command_name" == */* ]]; then
        [[ -x "$command_name" ]]
    else
        command -v "$command_name" >/dev/null 2>&1
    fi
}

audio_pactl_usable() {
    audio_have_cmd "$AUDIO_PACTL" || return 1
    "$AUDIO_PACTL" info >/dev/null 2>&1
}

audio_wpctl_usable() {
    audio_have_cmd "$AUDIO_WPCTL" || return 1
    "$AUDIO_WPCTL" status >/dev/null 2>&1
}

# Imprime o backend ativo: pipewire, pulseaudio ou none.
audio_backend() {
    local info=""

    if [[ -n "$AUDIO_BACKEND_DETECTED" ]]; then
        printf '%s\n' "$AUDIO_BACKEND_DETECTED"
        return 0
    fi

    if audio_pactl_usable; then
        info="$("$AUDIO_PACTL" info 2>/dev/null || true)"
        if grep -qi 'PipeWire' <<<"$info"; then
            AUDIO_BACKEND_DETECTED="pipewire"
        else
            AUDIO_BACKEND_DETECTED="pulseaudio"
        fi
    elif audio_wpctl_usable; then
        AUDIO_BACKEND_DETECTED="pipewire"
    else
        AUDIO_BACKEND_DETECTED="none"
    fi
    printf '%s\n' "$AUDIO_BACKEND_DETECTED"
}

audio_notify() {
    local title="$1"
    local body="$2"

    if audio_have_cmd "$AUDIO_NOTIFY"; then
        "$AUDIO_NOTIFY" -a Audio -u normal "$title" "$body" \
            >/dev/null 2>&1 || true
    fi
}

audio_refresh_status() {
    if audio_have_cmd "$AUDIO_PKILL"; then
        "$AUDIO_PKILL" -USR1 -x i3status 2>/dev/null || true
    fi
}

# ---------------------------------------------------------------- defaults

# Imprime o destino padrao da direcao (sink/source): nome no pactl, ID no
# wpctl. Vazio quando o servidor nao informar um padrao.
audio_default() {
    local direction="$1"

    if audio_pactl_usable; then
        "$AUDIO_PACTL" get-default-"$direction" 2>/dev/null || true
    elif audio_wpctl_usable; then
        audio_wpctl_default "$direction"
    fi
}

audio_wpctl_default() {
    local direction="$1"
    local section="Sinks"

    [[ "$direction" == source ]] && section="Sources"
    "$AUDIO_WPCTL" status 2>/dev/null | awk -v section="$section" '
        $0 ~ section ":[[:space:]]*$" { active = 1; next }
        active && match($0, /\*[[:space:]]*[0-9]+\./) {
            rest = substr($0, RSTART + 1)
            sub(/^[[:space:]]*/, "", rest)
            sub(/\..*$/, "", rest)
            print rest
            exit
        }
        active && /:[[:space:]]*$/ { exit }
    '
}

# No PipeWire nativo o padrao configurado pode nao ter estrela no status
# (ex.: quando o padrao do pactl e um monitor). Retorna o node.name do
# dispositivo configurado nas Settings, quando presente.
audio_wpctl_configured() {
    local direction="$1"
    local kind="Audio/Sink"

    [[ "$direction" == source ]] && kind="Audio/Source"
    "$AUDIO_WPCTL" status 2>/dev/null | awk -v kind="$kind" '
        $0 ~ /^[[:space:]]*Settings[[:space:]]*$/ { active = 1 }
        active && $0 ~ kind {
            line = $0
            sub(/^[[:space:]]*[0-9]+\.[[:space:]]*/, "", line)
            sub(kind "[[:space:]]+", "", line)
            sub(/^[[:space:]]+|[[:space:]]+$/, "", line)
            print line
            exit
        }
    '
}

audio_default_is() {
    local direction="$1"
    local target="$2"
    local current=""

    current="$(audio_default "$direction")"
    [[ -n "$current" && "$current" == "$target" ]]
}

# ----------------------------------------------------------------- listing

# Lista os dispositivos da direcao como linhas TSV:
# token<TAB>name<TAB>description<TAB>active_port<TAB>ports
# token e o alvo para set-default (nome no pactl, ID no wpctl); name e o
# node.name. ports agrupa "nome<TAB>descricao<TAB>disponibilidade" separados
# por \034 (disponibilidade: yes|no|unknown).
audio_list() {
    local direction="$1"

    if audio_pactl_usable; then
        audio_list_pactl "$direction"
    elif audio_wpctl_usable; then
        audio_list_wpctl "$direction"
    fi
}

audio_list_pactl() {
    local direction="$1"
    local list_type="sinks"

    [[ "$direction" == source ]] && list_type="sources"
    "$AUDIO_PACTL" list "$list_type" 2>/dev/null | awk '
        BEGIN { RS = "\n(Sink|Source) #" }
        {
            name = ""; description = ""; active_port = ""; ports = ""
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                if (line ~ /^[[:space:]]*Name:[[:space:]]+/) {
                    sub(/^[[:space:]]*Name:[[:space:]]+/, "", line)
                    name = line
                } else if (line ~ /^[[:space:]]*Description:[[:space:]]+/) {
                    sub(/^[[:space:]]*Description:[[:space:]]+/, "", line)
                    description = line
                } else if (line ~ /^[[:space:]]*Active Port:[[:space:]]+/) {
                    sub(/^[[:space:]]*Active Port:[[:space:]]+/, "", line)
                    active_port = line
                } else if (line ~ /^[[:space:]]+[a-z0-9-]+:[[:space:]]+.*\(type:/) {
                    sub(/^[[:space:]]+/, "", line)
                    colon = index(line, ":")
                    port_name = substr(line, 1, colon - 1)
                    rest = substr(line, colon + 2)
                    sub(/ \(type:.*$/, "", rest)
                    availability = "unknown"
                    if (line ~ /not available/) availability = "no"
                    else if (line ~ /availability unknown/) availability = "unknown"
                    else if (line ~ /availability yes/) availability = "yes"
                    ports = ports port_name "\t" rest "\t" availability "\034"
                }
            }
            if (name != "") print name "\t" name "\t" description "\t" active_port "\t" ports
        }
    '
}

audio_list_wpctl() {
    local direction="$1"
    local media_class="Audio/Sink"

    [[ "$direction" == source ]] && media_class="Audio/Source"
    if ! audio_have_cmd "$AUDIO_PWDUMP" || ! audio_have_cmd "$AUDIO_JQ"; then
        return 0
    fi
    "$AUDIO_PWDUMP" 2>/dev/null | "$AUDIO_JQ" -r --arg mc "$media_class" '
        [ .[] | select(.type == "PipeWire:Interface:Node")
            | select((.info.props // {})["media.class"] == $mc)
            | select((.info.props // {})["node.name"] != null)
            | [ (.id | tostring),
                (.info.props // {})["node.name"],
                ((.info.props // {})["node.description"] // "") ]
            | @tsv ] | unique | .[]
    ' 2>/dev/null || true
}

# Lista perfis de placas no pactl como TSV:
# card<TAB>card_description<TAB>profile<TAB>profile_description<TAB>
# sinks<TAB>sources<TAB>availability<TAB>active.
# Perfis sao importantes para headsets classicos: o microfone normalmente so
# existe depois que o perfil HFP/HSP e ativado.
audio_list_profiles() {
    if ! audio_pactl_usable; then
        return 0
    fi
    "$AUDIO_PACTL" list cards 2>/dev/null | awk '
        BEGIN { RS = "\nCard #" }
        {
            card_name = ""
            card_description = ""
            active_profile = ""
            in_profiles = 0
            profile_count = 0
            n = split($0, lines, "\n")
            for (i = 1; i <= n; i++) {
                line = lines[i]
                if (card_name == "" && line ~ /^[[:space:]]*Name:[[:space:]]+/) {
                    sub(/^[[:space:]]*Name:[[:space:]]+/, "", line)
                    card_name = line
                    continue
                }
                if (card_description == "" && line ~ /^[[:space:]]*Description:[[:space:]]+/) {
                    sub(/^[[:space:]]*Description:[[:space:]]+/, "", line)
                    card_description = line
                    continue
                }
                if (line ~ /^[[:space:]]*Profiles:[[:space:]]*$/) {
                    in_profiles = 1
                    continue
                }
                if (line ~ /^[[:space:]]*Active Profile:[[:space:]]+/) {
                    sub(/^[[:space:]]*Active Profile:[[:space:]]+/, "", line)
                    active_profile = line
                    in_profiles = 0
                    continue
                }
                if (in_profiles && line ~ /^[[:space:]]+[[:alnum:]_.+:-]+:[[:space:]].*\(sinks:[[:space:]]*[0-9]+,[[:space:]]*sources:[[:space:]]*[0-9]+/) {
                    sub(/^[[:space:]]+/, "", line)
                    separator = match(line, /:[[:space:]]/)
                    profile = substr(line, 1, separator - 1)
                    rest = substr(line, separator + RLENGTH)
                    description = rest
                    sub(/[[:space:]]+\(sinks:.*/, "", description)
                    sub(/^[[:space:]]+/, "", description)

                    sinks = rest
                    sub(/^.*\(sinks:[[:space:]]*/, "", sinks)
                    sub(/,.*/, "", sinks)
                    sources = rest
                    sub(/^.*sources:[[:space:]]*/, "", sources)
                    sub(/,.*/, "", sources)
                    availability = "unknown"
                    if (rest ~ /available:[[:space:]]+yes/) availability = "yes"
                    else if (rest ~ /available:[[:space:]]+no/) availability = "no"

                    profile_count++
                    profile_name[profile_count] = profile
                    profile_description[profile_count] = description
                    profile_sinks[profile_count] = sinks
                    profile_sources[profile_count] = sources
                    profile_availability[profile_count] = availability
                }
            }
            if (card_description == "") card_description = card_name
            for (i = 1; i <= profile_count; i++) {
                printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n",
                    card_name, card_description, profile_name[i],
                    profile_description[i], profile_sinks[i],
                    profile_sources[i], profile_availability[i],
                    (active_profile == profile_name[i] ? "yes" : "no")
            }
        }
    '
}

# Lista somente perfis Bluetooth que podem fornecer a direcao solicitada:
# card<TAB>card_description<TAB>profile<TAB>profile_description<TAB>active.
audio_list_profile_options() {
    local direction="$1"
    local card card_description profile profile_description sinks sources
    local availability active

    while IFS=$'\t' read -r card card_description profile profile_description \
        sinks sources availability active; do
        [[ "$card" == bluez_card.* ]] || continue
        [[ "$availability" != no ]] || continue
        if [[ "$direction" == sink && "$sinks" =~ ^[1-9][0-9]*$ ]] \
            || [[ "$direction" == source && "$sources" =~ ^[1-9][0-9]*$ ]]; then
            printf '%s\t%s\t%s\t%s\t%s\n' \
                "$card" "$card_description" "$profile" \
                "$profile_description" "$active"
        fi
    done < <(audio_list_profiles)
}

audio_set_profile() {
    local card="$1"
    local profile="$2"

    if audio_pactl_usable; then
        "$AUDIO_PACTL" set-card-profile "$card" "$profile"
    else
        return 1
    fi
}

# -------------------------------------------------------------- aplicacao

audio_set_default() {
    local direction="$1"
    local target="$2"

    if audio_pactl_usable; then
        "$AUDIO_PACTL" set-default-"$direction" "$target"
    else
        "$AUDIO_WPCTL" set-default "$target"
    fi
}

audio_set_port() {
    local direction="$1"
    local target="$2"
    local port="$3"

    "$AUDIO_PACTL" set-"$direction"-port "$target" "$port"
}

# Move as streams ativas para o novo destino e imprime quantas foram movidas.
# No PipeWire nativo nao ha equivalente estavel; novas aplicacoes seguem o
# padrao e o retorno e zero.
audio_move_streams() {
    local direction="$1"
    local target="$2"
    local kind="" move_cmd="" ids="" id=""
    local moved=0

    if ! audio_pactl_usable; then
        printf '0\n'
        return 0
    fi
    if [[ "$direction" == sink ]]; then
        kind="sink-inputs"
        move_cmd="move-sink-input"
    else
        kind="source-outputs"
        move_cmd="move-source-output"
    fi

    ids="$("$AUDIO_PACTL" list "$kind" short 2>/dev/null | awk '{print $1}')"
    while IFS= read -r id; do
        [[ -n "$id" ]] || continue
        if "$AUDIO_PACTL" "$move_cmd" "$id" "$target" >/dev/null 2>&1; then
            moved=$((moved + 1))
        fi
    done <<<"$ids"
    printf '%s\n' "$moved"
}

# ----------------------------------------------------------- volume/mute

audio_pactl_percent() {
    local direction="$1"
    local target="$2"

    "$AUDIO_PACTL" get-"$direction"-volume "$target" 2>/dev/null \
        | sed -n 's/.*front-left: [0-9]* \/ *\([0-9]*\)%.*/\1/p'
}

audio_volume_step() {
    local direction="$1"
    local action="$2"
    local step="$3"
    local max_percent="$4"
    local target="" current="" next=""
    if audio_pactl_usable; then
        target="$(audio_default "$direction")"
        [[ -n "$target" ]] || return 1
        current="$(audio_pactl_percent "$direction" "$target")"
        [[ -n "$current" ]] || return 1
    elif audio_wpctl_usable; then
        target="$(audio_wpctl_default "$direction")"
        [[ -n "$target" ]] || return 1
        current="$(
            "$AUDIO_WPCTL" get-volume "$target" 2>/dev/null \
                | awk '/Volume:/ { printf "%d\n", $2 * 100 + 0.5; exit }'
        )"
        [[ -n "$current" ]] || return 1
    else
        return 1
    fi

    if [[ "$action" == up ]]; then
        next=$(( (current / step + 1) * step ))
    else
        next=$(( ((current + step - 1) / step - 1) * step ))
    fi
    ((next > max_percent)) && next=$max_percent
    ((next < 0)) && next=0

    if audio_pactl_usable; then
        "$AUDIO_PACTL" set-"$direction"-volume "$target" "${next}%"
    else
        "$AUDIO_WPCTL" set-volume "$target" "${next}%"
    fi
}

audio_mute_toggle() {
    local direction="$1"

    if audio_pactl_usable; then
        "$AUDIO_PACTL" set-"$direction"-mute "@DEFAULT_${direction^^}@" toggle
    elif audio_wpctl_usable; then
        local target=""
        target="$(audio_wpctl_default "$direction")"
        [[ -n "$target" ]] || return 1
        "$AUDIO_WPCTL" set-mute "$target" toggle
    else
        return 1
    fi
}
