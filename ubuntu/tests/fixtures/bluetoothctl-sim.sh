#!/usr/bin/env bash
set -Eeuo pipefail

state_dir="${TEST_STATE_DIR:?TEST_STATE_DIR is required}"
scan_started="$state_dir/scan-started"
scan_stopped="$state_dir/scan-stopped"
paired="$state_dir/paired"
connected="$state_dir/connected"
power_on="$state_dir/power-on"
command_log="$state_dir/bluetoothctl-commands.log"
initial_state="$state_dir/initial-state"
device_kind="${TEST_DEVICE_KIND:-headset}"
second_device="${TEST_SECOND_DEVICE:-0}"

addr1='AA:BB:CC:DD:EE:FF'
addr2='BB:CC:DD:EE:FF:00'
paired2="$state_dir/paired2"
connected2="$state_dir/connected2"

device_label_for() {
    local addr="$1"
    if [[ "$addr" == "$addr2" ]]; then
        printf 'Simulated Speaker'
    elif [[ "$device_kind" == hid ]]; then
        printf 'Simulated Mouse'
    else
        printf 'Simulated Headset'
    fi
}

paired_file_for() {
    if [[ "$1" == "$addr2" ]]; then printf '%s' "$paired2"; else printf '%s' "$paired"; fi
}

connected_file_for() {
    if [[ "$1" == "$addr2" ]]; then printf '%s' "$connected2"; else printf '%s' "$connected"; fi
}

if [[ "${TEST_PAIRED:-0}" == 1 && ! -e "$initial_state" ]]; then
    : >"$paired"
    if [[ "${TEST_CONNECTED:-1}" == 1 ]]; then
        : >"$connected"
    fi
    if [[ "$second_device" == 1 ]]; then
        : >"$paired2"
        if [[ "${TEST_CONNECTED:-1}" == 1 ]]; then
            : >"$connected2"
        fi
    fi
    : >"$initial_state"
fi

record_command() {
    printf '%s\n' "$1" >>"$command_log"
}

now() {
    date +%s
}

device_is_visible() {
    [[ -f "$scan_started" ]] || return 1
    (( $(now) - $(<"$scan_started") >= ${TEST_DEVICE_DELAY:-2} ))
}

print_devices() {
    if device_is_visible && [[ ! -f "$paired" ]]; then
        printf 'Device %s %s\n' "$addr1" "$(device_label_for "$addr1")"
    fi
}

print_info() {
    local addr="$1"
    local pfile cfile label
    pfile="$(paired_file_for "$addr")"
    cfile="$(connected_file_for "$addr")"
    label="$(device_label_for "$addr")"

    if [[ -f "$pfile" ]]; then
        printf 'Device %s %s\n' "$addr" "$label"
        if [[ -f "$cfile" ]]; then
            cat <<'EOF'
	Paired: yes
	Connected: yes
	ServicesResolved: yes
EOF
        else
            cat <<'EOF'
	Paired: yes
	Connected: no
EOF
        fi
    else
        printf 'Device %s %s\n\tPaired: no\n' "$addr" "$label"
    fi

    if [[ "$device_kind" == hid && -f "$pfile" ]]; then
        printf '\tUUID: Human Interface Device (00001124-0000-1000-8000-00805f9b34fb)\n'
    elif [[ "$device_kind" != hid && -f "$pfile" ]]; then
        printf '\tUUID: Audio Sink (0000110b-0000-1000-8000-00805f9b34fb)\n'
    fi
}

do_connect() {
    local addr="$1"

    record_command "connect $addr"
    if [[ "$addr" == "$addr2" ]]; then
        : >"$state_dir/connect-started2"
        sleep "${TEST_CONNECT_DELAY2:-0}"
        : >"$connected2"
    else
        : >"$state_dir/connect-started"
        if [[ "${TEST_CONNECT_DELAY:-0}" =~ ^[0-9]+$ ]]; then
            sleep "${TEST_CONNECT_DELAY:-0}"
        fi
        : >"$connected"
    fi
}

if (($# > 0)); then
    case "$1" in
        show)
            printf 'Controller 00:11:22:33:44:55 (public)\n\tPowered: %s\n' \
                "${TEST_POWERED:-yes}"
            ;;
        info)
            print_info "${2:-$addr1}"
            ;;
        power)
            [[ "${2:-}" == on ]] && : >"$power_on"
            ;;
        trust)
            record_command "$*"
            ;;
        connect)
            do_connect "${2:-$addr1}"
            ;;
        disconnect)
            record_command "$*"
            if [[ "${TEST_DISCONNECT_FAIL:-0}" == 1 ]]; then
                exit 1
            fi
            rm -f -- "$(connected_file_for "${2:-$addr1}")"
            ;;
        remove)
            record_command "$*"
            if [[ "${TEST_REMOVE_FAIL:-0}" == 1 ]]; then
                printf 'Failed to remove device\n' >&2
                exit 1
            fi
            rm -f -- "$(paired_file_for "${2:-$addr1}")" \
                "$(connected_file_for "${2:-$addr1}")"
            ;;
        *)
            ;;
    esac
    exit 0
fi

while IFS= read -r command; do
    case "$command" in
        show)
            printf 'Controller 00:11:22:33:44:55 (public)\n\tPowered: %s\n' \
                "${TEST_POWERED:-yes}"
            ;;
        power\ on)
            : >"$power_on"
            ;;
        devices)
            print_devices
            ;;
        devices\ Paired)
            if [[ -f "$paired" ]]; then
                printf 'Device %s %s\n' "$addr1" "$(device_label_for "$addr1")"
            fi
            if [[ "$second_device" == 1 && -f "$paired2" ]]; then
                printf 'Device %s %s\n' "$addr2" "$(device_label_for "$addr2")"
            fi
            ;;
        paired-devices)
            if [[ -f "$paired" ]]; then
                printf 'Device %s %s\n' "$addr1" "$(device_label_for "$addr1")"
            fi
            if [[ "$second_device" == 1 && -f "$paired2" ]]; then
                printf 'Device %s %s\n' "$addr2" "$(device_label_for "$addr2")"
            fi
            ;;
        devices\ Connected)
            if [[ -f "$connected" ]]; then
                printf 'Device %s %s\n' "$addr1" "$(device_label_for "$addr1")"
            fi
            if [[ "$second_device" == 1 && -f "$connected2" ]]; then
                printf 'Device %s %s\n' "$addr2" "$(device_label_for "$addr2")"
            fi
            ;;
        scan\ on)
            now >"$scan_started"
            ;;
        scan\ off)
            : >"$scan_stopped"
            ;;
        pair\ *)
            if [[ "${TEST_PAIR_PIN:-0}" == 1 ]]; then
                printf 'Request PIN code:\n'
                IFS= read -r pin || true
                printf 'Received PIN %s\n' "$pin" >>"$command_log"
            fi
            : >"$paired"
            : >"$connected"
            printf '[CHG] Device %s Paired: yes\n' "$addr1"
            printf 'Pairing successful\n'
            printf 'Connection successful\n'
            ;;
        connect\ *)
            record_command "$command"
            addr="${command#connect }"
            addr="${addr%% *}"
            : >"$(connected_file_for "$addr")"
            ;;
        disconnect\ *)
            record_command "$command"
            if [[ "${TEST_DISCONNECT_FAIL:-0}" != 1 ]]; then
                addr="${command#disconnect }"
                addr="${addr%% *}"
                rm -f -- "$(connected_file_for "$addr")"
            fi
            ;;
        remove\ *)
            record_command "$command"
            if [[ "${TEST_REMOVE_FAIL:-0}" != 1 ]]; then
                addr="${command#remove }"
                addr="${addr%% *}"
                rm -f -- "$(paired_file_for "$addr")" "$(connected_file_for "$addr")"
            else
                printf 'Failed to remove device\n'
            fi
            ;;
        quit)
            exit 0
            ;;
    esac
done
