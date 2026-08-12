#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/.config/i3/bluetooth-menu.sh"
bluetoothctl_sim="$repo_dir/tests/fixtures/bluetoothctl-sim.sh"
dmenu_sim="$repo_dir/tests/fixtures/dmenu-sim.sh"
pactl_sim="$repo_dir/tests/fixtures/pactl-sim.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

run_case() {
    local name="$1"
    shift
    local state="$test_root/$name"
    local audio_pactl_bin="$state/no-pactl"
    if [[ "${TEST_AUDIO_BACKEND:-0}" == 1 ]]; then
        audio_pactl_bin="$pactl_sim"
    fi
    mkdir -p "$state/runtime"
    env \
        HOME="$test_root/home-$name" \
        XDG_STATE_HOME="$state/state" \
        XDG_RUNTIME_DIR="$state/runtime" \
        TEST_STATE_DIR="$state" \
        BLUETOOTHCTL_BIN="$bluetoothctl_sim" \
        BLUETOOTH_MENU_BIN="$dmenu_sim" \
        NOTIFY_SEND_BIN="$state/no-notify-send" \
        RFKILL_BIN="$state/no-rfkill" \
        PKILL_BIN="$state/no-pkill" \
        AUDIO_PACTL_BIN="$audio_pactl_bin" \
        AUDIO_WPCTL_BIN="$state/no-wpctl" \
        BLUETOOTH_SCAN_SECONDS="${BLUETOOTH_SCAN_SECONDS:-5}" \
        BLUETOOTH_AUDIO_WAIT_SECONDS="${BLUETOOTH_AUDIO_WAIT_SECONDS:-12}" \
        TEST_POWERED="${TEST_POWERED:-yes}" \
        TEST_DEVICE_DELAY="${TEST_DEVICE_DELAY:-2}" \
        TEST_PAIRED="${TEST_PAIRED:-0}" \
        TEST_CONNECTED="${TEST_CONNECTED:-1}" \
        TEST_DEVICE_KIND="${TEST_DEVICE_KIND:-headset}" \
        TEST_PAIR_PIN="${TEST_PAIR_PIN:-0}" \
        TEST_DMENU_PIN="${TEST_DMENU_PIN:-0000}" \
        TEST_CONNECT_DELAY="${TEST_CONNECT_DELAY:-0}" \
        TEST_CONNECT_DELAY2="${TEST_CONNECT_DELAY2:-0}" \
        TEST_DMENU_ACTION="${TEST_DMENU_ACTION:-connect}" \
        TEST_DMENU_CONFIRM="${TEST_DMENU_CONFIRM:-1}" \
        TEST_DMENU_PICK="${TEST_DMENU_PICK:-1}" \
        TEST_SECOND_DEVICE="${TEST_SECOND_DEVICE:-0}" \
        TEST_REMOVE_FAIL="${TEST_REMOVE_FAIL:-0}" \
        TEST_DISCONNECT_FAIL="${TEST_DISCONNECT_FAIL:-0}" \
        "$@" "$script"
}

mkdir -p "$test_root/home-select"
TEST_DEVICE_DELAY=6 run_case select bash

select_log="$test_root/select/dmenu.log"
[[ "$(grep -c $'Bluetooth > Conectar novo dispositivo\t' "$select_log")" -ge 2 ]]
grep -Eq $'^Bluetooth\t.*󰂲 Desligar Bluetooth' "$select_log"
grep $'^Bluetooth > Conectar novo dispositivo\t' "$select_log" | sed -n '1p' \
    | grep -q 'Procurando dispositivos'
grep $'^Bluetooth > Conectar novo dispositivo\t' "$select_log" | grep -q 'Simulated Headset'
[[ -f "$test_root/select/scan-stopped" ]]
[[ -f "$test_root/select/paired" ]]

mkdir -p "$test_root/home-cancel"
TEST_DMENU_CANCEL=1 run_case cancel bash
[[ -f "$test_root/cancel/scan-stopped" ]]
[[ ! -f "$test_root/cancel/paired" ]]

mkdir -p "$test_root/powered-off"
TEST_POWERED=no run_case powered-off bash
powered_off_log="$test_root/powered-off/dmenu.log"
[[ "$(grep -c $'^Bluetooth\t' "$powered_off_log")" -eq 1 ]]
grep -Eq $'^Bluetooth\t.*󰂯  Ativar Bluetooth$' "$powered_off_log"
! grep -Eq 'Conectar novo dispositivo|Parear novo dispositivo|Procurar dispositivos|Procurando dispositivos' "$powered_off_log"
[[ ! -f "$test_root/powered-off/scan-started" ]]
[[ ! -f "$test_root/powered-off/scan-stopped" ]]
[[ -f "$test_root/powered-off/power-on" ]]

mkdir -p "$test_root/forget"
TEST_PAIRED=1 TEST_DMENU_ACTION=forget run_case forget bash
forget_log="$test_root/forget/dmenu.log"
grep -q 'Gerenciar: Simulated Headset' "$forget_log"
grep -Eq $'^Bluetooth > Simulated Headset\t' "$forget_log"
grep -q '^Esquecer dispositivo$' "$forget_log"
grep -Eq $'^Bluetooth > Simulated Headset > Esquecer[?]\t.*Confirmar esquecimento' "$forget_log"
[[ "$(sed -n '1,2p' "$test_root/forget/bluetoothctl-commands.log")" == $'disconnect AA:BB:CC:DD:EE:FF\nremove AA:BB:CC:DD:EE:FF' ]]
[[ ! -f "$test_root/forget/paired" ]]

mkdir -p "$test_root/forget-disconnect-failure"
TEST_PAIRED=1 TEST_DMENU_ACTION=forget TEST_DISCONNECT_FAIL=1 \
    run_case forget-disconnect-failure bash
[[ ! -f "$test_root/forget-disconnect-failure/paired" ]]
[[ "$(sed -n '1,2p' "$test_root/forget-disconnect-failure/bluetoothctl-commands.log")" == $'disconnect AA:BB:CC:DD:EE:FF\nremove AA:BB:CC:DD:EE:FF' ]]

mkdir -p "$test_root/forget-back"
TEST_PAIRED=1 TEST_DMENU_ACTION=forget TEST_DMENU_CONFIRM=back \
    run_case forget-back bash
[[ -f "$test_root/forget-back/paired" ]]
[[ ! -f "$test_root/forget-back/bluetoothctl-commands.log" ]]
grep -q '^Voltar$' "$test_root/forget-back/dmenu.log"

mkdir -p "$test_root/manage-back"
TEST_PAIRED=1 TEST_DMENU_ACTION=back run_case manage-back bash
[[ -f "$test_root/manage-back/paired" ]]
[[ ! -f "$test_root/manage-back/bluetoothctl-commands.log" ]]
[[ "$(grep -c $'^Bluetooth\t' "$test_root/manage-back/dmenu.log")" -eq 2 ]]
grep -q '^Voltar$' "$test_root/manage-back/dmenu.log"

mkdir -p "$test_root/connection-busy"
TEST_PAIRED=1 TEST_CONNECTED=0 TEST_DMENU_ACTION=connect TEST_CONNECT_DELAY=5 \
    run_case connection-busy bash &
connection_pid=$!
for _ in {1..50}; do
    [[ -f "$test_root/connection-busy/connect-started" ]] && break
    sleep 0.1
done
[[ -f "$test_root/connection-busy/connect-started" ]]
TEST_PAIRED=1 TEST_DMENU_ACTION=back run_case connection-busy bash
wait "$connection_pid"
grep -q $'^Bluetooth\t' "$test_root/connection-busy/dmenu.log"

# Enquanto o dispositivo 1 conecta, o menu deve abrir e conectar o dispositivo 2.
mkdir -p "$test_root/connection-other-device"
TEST_PAIRED=1 TEST_CONNECTED=0 TEST_SECOND_DEVICE=1 TEST_DMENU_ACTION=connect \
    TEST_CONNECT_DELAY=8 run_case connection-other-device bash &
other_pid=$!
for _ in {1..50}; do
    [[ -f "$test_root/connection-other-device/connect-started" ]] && break
    sleep 0.1
done
[[ -f "$test_root/connection-other-device/connect-started" ]]
TEST_PAIRED=1 TEST_CONNECTED=0 TEST_SECOND_DEVICE=1 TEST_DMENU_ACTION=connect \
    TEST_DMENU_PICK=2 run_case connection-other-device bash
wait "$other_pid"
[[ -f "$test_root/connection-other-device/connect-started2" ]]
grep -q '^connect BB:CC:DD:EE:FF:00$' \
    "$test_root/connection-other-device/bluetoothctl-commands.log"

# Operação no mesmo dispositivo ainda em conexão é recusada, sem repetir o connect.
mkdir -p "$test_root/connection-same-device"
TEST_PAIRED=1 TEST_CONNECTED=0 TEST_DMENU_ACTION=connect TEST_CONNECT_DELAY=8 \
    run_case connection-same-device bash &
same_pid=$!
for _ in {1..50}; do
    [[ -f "$test_root/connection-same-device/connect-started" ]] && break
    sleep 0.1
done
[[ -f "$test_root/connection-same-device/connect-started" ]]
TEST_PAIRED=1 TEST_CONNECTED=0 TEST_DMENU_ACTION=connect TEST_DMENU_PICK=1 \
    run_case connection-same-device bash
wait "$same_pid"
[[ "$(grep -c '^connect AA:BB:CC:DD:EE:FF$' \
    "$test_root/connection-same-device/bluetoothctl-commands.log")" -eq 1 ]]
grep -q 'ocupado' "$test_root/connection-same-device/state/ubuntu-i3/bluetooth.log"

mkdir -p "$test_root/forget-failure"
TEST_PAIRED=1 TEST_DMENU_ACTION=forget TEST_REMOVE_FAIL=1 \
    run_case forget-failure bash
[[ -f "$test_root/forget-failure/paired" ]]
grep -q 'falha ao esquecer' "$test_root/forget-failure/state/ubuntu-i3/bluetooth.log"

mkdir -p "$test_root/pair-pin-first"
TEST_PAIR_PIN=1 TEST_DEVICE_DELAY=1 run_case pair-pin-first bash
pair_pin_log="$test_root/pair-pin-first/dmenu.log"
grep -q '^PIN do Bluetooth para AA:BB:CC:DD:EE:FF' "$pair_pin_log"
grep -q 'Received PIN 0000' "$test_root/pair-pin-first/bluetoothctl-commands.log"
[[ -f "$test_root/pair-pin-first/paired" ]]

# A janela de PIN e o agente terminam junto com o primeiro menu. Uma segunda
# execução deve conseguir adquirir o mesmo lock e abrir o submenu normalmente.
TEST_DMENU_ACTION=connect run_case pair-pin-first bash
grep -q 'Gerenciar: Simulated Headset' \
    "$test_root/pair-pin-first/dmenu.log"
grep -q $'^Bluetooth > Simulated Headset\t' \
    "$test_root/pair-pin-first/dmenu.log"

mkdir -p "$test_root/hid"
hid_start="$(date +%s)"
TEST_AUDIO_BACKEND=1 TEST_DEVICE_KIND=hid TEST_DEVICE_DELAY=0 \
    BLUETOOTH_SCAN_SECONDS=1 BLUETOOTH_AUDIO_WAIT_SECONDS=8 \
    run_case hid bash
hid_elapsed=$(( $(date +%s) - hid_start ))
((hid_elapsed < 6))
grep -q 'dispositivo sem perfil de audio' \
    "$test_root/hid/state/ubuntu-i3/bluetooth.log"

printf 'bluetooth-menu simulated discovery: ok\n'
