#!/usr/bin/env bash
set -Eeuo pipefail

# Simula os comandos nmcli usados pelo wifi-menu.sh. O estado (radio, perfis
# salvos e conexao ativa) persiste entre invocacoes em arquivos sob
# TEST_STATE_DIR e pode ser controlado pelas variaveis TEST_*.

state_dir="${TEST_STATE_DIR:?TEST_STATE_DIR is required}"
command_log="$state_dir/nmcli-commands.log"
radio_file="$state_dir/radio"
active_file="$state_dir/active-uuid"
profiles_file="$state_dir/profiles.tsv"

uuid1='11111111-1111-1111-1111-111111111111'
uuid2='22222222-2222-2222-2222-222222222222'

record_command() {
    printf '%s\n' "$*" >>"$command_log"
}

mkdir -p "$state_dir"

if [[ ! -e "$state_dir/initialized" ]]; then
    : >"$profiles_file"
    : >"$active_file"
    printf '%s\n' "${TEST_RADIO:-enabled}" >"$radio_file"
    if [[ "${TEST_SAVED:-0}" == 1 ]]; then
        printf 'HomeWiFi\t%s\t802-11-wireless\n' "$uuid1" >>"$profiles_file"
        if [[ "${TEST_CONNECTED:-0}" == 1 ]]; then
            printf '%s\n' "$uuid1" >"$active_file"
        fi
    fi
    : >"$state_dir/initialized"
fi

args=()
fields=''
skip_next=0
for arg in "$@"; do
    if ((skip_next)); then
        case "$arg" in
            NAME,UUID,TYPE|UUID|NAME,UUID|DEVICE,TYPE|IN-USE,SSID,SIGNAL,SECURITY|GENERAL.CONNECTION|connection.type)
                fields="$arg"
                ;;
        esac
        skip_next=0
        continue
    fi
    case "$arg" in
        -t) continue ;;
        -e) skip_next=1; continue ;;
        -f) skip_next=1; continue ;;
        --ask) continue ;;
    esac
    args+=("$arg")
done

case "${args[0]:-}" in
    radio)
        case "${args[1]:-}" in
            wifi)
                if [[ "${args[2]:-}" == on ]]; then
                    record_command "${args[*]}"
                    printf 'enabled\n' >"$radio_file"
                elif [[ "${args[2]:-}" == off ]]; then
                    record_command "${args[*]}"
                    printf 'disabled\n' >"$radio_file"
                    : >"$active_file"
                else
                    cat "$radio_file"
                fi
                ;;
        esac
        ;;
    device)
        case "${args[1]:-}" in
            status)
                printf 'wlan0:wifi\n'
                ;;
            show)
                if [[ "$(<"$radio_file")" == enabled && -s "$active_file" ]]; then
                    active="$(<"$active_file")"
                    name="$(awk -F'\t' -v u="$active" '$2 == u { print $1; exit }' \
                        "$profiles_file")"
                    [[ -n "$name" ]] && printf 'GENERAL.CONNECTION:%s\n' "$name"
                fi
                ;;
            disconnect)
                record_command "${args[*]}"
                : >"$active_file"
                ;;
            wifi)
                case "${args[2]:-}" in
                    list)
                        # device wifi list --rescan no
                        if [[ "$(<"$radio_file")" == enabled ]]; then
                            if [[ "$(<"$active_file")" == "$uuid1" ]]; then
                                printf '*:HomeWiFi:85:WPA2\n'
                            else
                                printf ':HomeWiFi:85:WPA2\n'
                            fi
                            printf ':NeighborNet:45:WPA2\n'
                        fi
                        ;;
                    rescan)
                        record_command "${args[*]}"
                        : >"$state_dir/wifi-rescan"
                        ;;
                    connect)
                        record_command "${args[*]}"
                        if [[ "${TEST_WIFI_CONNECT_FAIL:-0}" == 1 ]]; then
                            printf 'Erro: falha de autenticação\n' >&2
                            exit 1
                        fi
                        printf '%s\n' "${args[3]:-}" >"$state_dir/connected-ssid"
                        ;;
                esac
                ;;
        esac
        ;;
    connection)
        case "${args[1]:-}" in
            show)
                if [[ "${args[2]:-}" == --active ]]; then
                    if [[ -s "$active_file" ]]; then
                        active="$(<"$active_file")"
                        name="$(awk -F'\t' -v u="$active" '$2 == u { print $1; exit }' \
                            "$profiles_file")"
                        [[ -n "$name" ]] && printf '%s:%s\n' "$name" "$active"
                    fi
                elif [[ "${args[2]:-}" == id ]]; then
                    name="${args[3]:-}"
                    if awk -F'\t' -v n="$name" '$1 == n { found = 1 }
                        END { exit !found }' "$profiles_file"; then
                        printf 'connection.type:802-11-wireless\n'
                    fi
                elif [[ "$fields" == UUID ]]; then
                    cut -f2 "$profiles_file"
                else
                    awk -F'\t' '{ printf "%s:%s:%s\n", $1, $2, $3 }' \
                        "$profiles_file"
                fi
                ;;
            up)
                record_command "${args[*]}"
                target="${args[3]:-}"
                if [[ "$(<"$radio_file")" != enabled ]]; then
                    exit 1
                fi
                if [[ "${args[2]:-}" == uuid ]]; then
                    if ! awk -F'\t' -v u="$target" '$2 == u { found = 1 }
                        END { exit !found }' "$profiles_file"; then
                        exit 1
                    fi
                    printf '%s\n' "$target" >"$active_file"
                else
                    uuid="$(awk -F'\t' -v n="$target" '$1 == n { print $2; exit }' \
                        "$profiles_file")"
                    [[ -n "$uuid" ]] || exit 1
                    printf '%s\n' "$uuid" >"$active_file"
                fi
                ;;
            down)
                record_command "${args[*]}"
                target="${args[3]:-}"
                if [[ "$(<"$active_file")" == "$target" ]]; then
                    : >"$active_file"
                fi
                ;;
            delete)
                record_command "${args[*]}"
                target="${args[3]:-}"
                if [[ "${TEST_DELETE_FAIL:-0}" == 1 ]]; then
                    printf 'Erro: falha ao remover o perfil\n' >&2
                    exit 1
                fi
                grep -Fv -- "$target" "$profiles_file" >"$profiles_file.tmp" \
                    && mv "$profiles_file.tmp" "$profiles_file"
                if [[ "$(<"$active_file")" == "$target" ]]; then
                    : >"$active_file"
                fi
                ;;
        esac
        ;;
esac
