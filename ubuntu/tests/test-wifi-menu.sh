#!/usr/bin/env bash
set -Eeuo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo_dir/.config/i3/wifi-menu.sh"
nmcli_sim="$repo_dir/tests/fixtures/nmcli-sim.sh"
dmenu_sim="$repo_dir/tests/fixtures/dmenu-sim-wifi.sh"
test_root="$(mktemp -d)"
trap 'rm -rf -- "$test_root"' EXIT

run_case() {
    local name="$1"
    shift
    local state="$test_root/$name"
    mkdir -p "$state/runtime" "$state/home"
    env \
        HOME="$state/home" \
        XDG_RUNTIME_DIR="$state/runtime" \
        WIFI_MENU_DEBUG_LOG="$state/wifi-menu-debug.log" \
        TEST_STATE_DIR="$state" \
        NMCLI_BIN="$nmcli_sim" \
        WIFI_MENU_BIN="$dmenu_sim" \
        WALKER_BIN="$state/no-walker" \
        ALACRITTY_BIN="$state/no-alacritty" \
        NOTIFY_SEND_BIN="$state/no-notify-send" \
        TEST_RADIO="${TEST_RADIO:-enabled}" \
        TEST_SAVED="${TEST_SAVED:-0}" \
        TEST_CONNECTED="${TEST_CONNECTED:-0}" \
        TEST_DELETE_FAIL="${TEST_DELETE_FAIL:-0}" \
        TEST_WIFI_CONNECT_FAIL="${TEST_WIFI_CONNECT_FAIL:-0}" \
        TEST_WIFI_PASSWORD="${TEST_WIFI_PASSWORD:-}" \
        TEST_DMENU_ACTION="${TEST_DMENU_ACTION:-radio-off}" \
        TEST_SUBMENU_ACTION="${TEST_SUBMENU_ACTION:-connect}" \
        "$@" "$script"
}

uuid1='11111111-1111-1111-1111-111111111111'

# Radio desligado: a unica opcao visivel e ativar o Wi-Fi.
mkdir -p "$test_root/radio-off"
TEST_RADIO=disabled run_case radio-off bash
radio_log="$test_root/radio-off/dmenu.log"
[[ "$(grep -c $'^Wi-Fi\t' "$radio_log")" -eq 1 ]]
grep -Eq $'^Wi-Fi\t󰤨  Ativar Wi-Fi$' "$radio_log"
! grep -Eq 'Gerenciar:|Desativar|Desconectar|HomeWiFi|NeighborNet' "$radio_log"
grep -q '^radio wifi on$' "$test_root/radio-off/nmcli-commands.log"
[[ "$(<"$test_root/radio-off/radio")" == enabled ]]

# Radio ligado: menu principal sem redes visiveis (novas ou salvas) e sem o
# editor de conexoes; redes novas ficam no submenu de descoberta.
mkdir -p "$test_root/main-on"
TEST_SAVED=1 TEST_CONNECTED=1 TEST_DMENU_ACTION=radio-off run_case main-on bash
main_log="$test_root/main-on/dmenu.log"
grep -q $'^Wi-Fi\t󰤮  Desativar Wi-Fi$' "$main_log"
grep -q $'^󰬡  Conectar nova rede Wi-Fi$' "$main_log"
grep -q $'^󰖪  Desconectar de HomeWiFi$' "$main_log"
grep -q $'^󰒓  Gerenciar: HomeWiFi$' "$main_log"
! grep -q 'NeighborNet' "$main_log"
! grep -q 'HomeWiFi · ' "$main_log"
! grep -q 'Gerenciar conexoes' "$main_log"
grep -q '^radio wifi off$' "$test_root/main-on/nmcli-commands.log"
[[ "$(<"$test_root/main-on/radio")" == disabled ]]

# Submenu de rede salva desconectada: breadcrumb e conectar.
mkdir -p "$test_root/manage-connect"
TEST_SAVED=1 TEST_CONNECTED=0 TEST_DMENU_ACTION=manage run_case manage-connect bash
manage_log="$test_root/manage-connect/dmenu.log"
grep -q $'^󰒓  Gerenciar: HomeWiFi$' "$manage_log"
grep -q $'^Wi-Fi > HomeWiFi\tConectar$' "$manage_log"
grep -q '^Esquecer rede$' "$manage_log"
grep -q '^Voltar$' "$manage_log"
grep -q "^connection up uuid $uuid1$" \
    "$test_root/manage-connect/nmcli-commands.log"
[[ "$(<"$test_root/manage-connect/active-uuid")" == "$uuid1" ]]

# Submenu de rede salva conectada: desconectar.
mkdir -p "$test_root/manage-disconnect"
TEST_SAVED=1 TEST_CONNECTED=1 TEST_DMENU_ACTION=manage run_case manage-disconnect bash
grep -q $'^Wi-Fi > HomeWiFi\tDesconectar$' "$test_root/manage-disconnect/dmenu.log"
grep -q "^connection down uuid $uuid1$" \
    "$test_root/manage-disconnect/nmcli-commands.log"
[[ ! -s "$test_root/manage-disconnect/active-uuid" ]]

# Esquecer com confirmacao: desconecta e remove o perfil.
mkdir -p "$test_root/forget"
TEST_SAVED=1 TEST_CONNECTED=1 TEST_DMENU_ACTION=manage TEST_SUBMENU_ACTION=forget run_case forget bash
forget_log="$test_root/forget/dmenu.log"
grep -q $'^Wi-Fi > HomeWiFi > Esquecer?\t' "$forget_log"
grep -q $'^Wi-Fi > HomeWiFi > Esquecer?\tConfirmar esquecimento$' "$forget_log"
grep -q "^connection down uuid $uuid1$" "$test_root/forget/nmcli-commands.log"
grep -q "^connection delete uuid $uuid1$" "$test_root/forget/nmcli-commands.log"
! grep -q "$uuid1" "$test_root/forget/profiles.tsv"

# Esquecer cancelado: o perfil permanece, sem desconectar nem remover.
mkdir -p "$test_root/forget-back"
TEST_SAVED=1 TEST_DMENU_ACTION=manage TEST_SUBMENU_ACTION=forget TEST_DMENU_CONFIRM=back \
    run_case forget-back bash
grep -q '^Voltar$' "$test_root/forget-back/dmenu.log"
grep -q "$uuid1" "$test_root/forget-back/profiles.tsv"
[[ ! -e "$test_root/forget-back/nmcli-commands.log" ]] \
    || ! grep -Eq '^connection (down|delete)' \
        "$test_root/forget-back/nmcli-commands.log"

# Voltar do submenu reexibe o menu principal.
mkdir -p "$test_root/manage-back"
TEST_SAVED=1 TEST_DMENU_ACTION=manage TEST_SUBMENU_ACTION=back run_case manage-back bash
[[ "$(grep -c $'^Wi-Fi\t' "$test_root/manage-back/dmenu.log")" -eq 2 ]]
grep -q '^Voltar$' "$test_root/manage-back/dmenu.log"

# Falha ao remover o perfil: o perfil permanece salvo.
mkdir -p "$test_root/forget-failure"
TEST_SAVED=1 TEST_DMENU_ACTION=manage TEST_SUBMENU_ACTION=forget TEST_DELETE_FAIL=1 \
    run_case forget-failure bash
grep -q "$uuid1" "$test_root/forget-failure/profiles.tsv"

# Conectar nova rede: submenu de descoberta exclui redes salvas, pede a senha
# pelo dmenu e conecta.
mkdir -p "$test_root/discover-password"
TEST_SAVED=1 TEST_DMENU_ACTION=discover TEST_WIFI_PASSWORD='secret123' \
    run_case discover-password bash
discover_log="$test_root/discover-password/dmenu.log"
grep -q $'^󰬡  Conectar nova rede Wi-Fi$' "$discover_log"
grep -q $'^Wi-Fi > Conectar nova rede\t' "$discover_log"
grep $'^Wi-Fi > Conectar nova rede\t' "$discover_log" | grep -q 'NeighborNet'
! grep $'^Wi-Fi > Conectar nova rede\t' "$discover_log" | grep -q 'HomeWiFi'
grep -q $'^Senha do Wi-Fi para NeighborNet\t' "$discover_log"
grep -q '^device wifi rescan$' \
    "$test_root/discover-password/nmcli-commands.log"
grep -q '^device wifi connect NeighborNet password secret123$' \
    "$test_root/discover-password/nmcli-commands.log"
[[ "$(<"$test_root/discover-password/connected-ssid")" == NeighborNet ]]

# Senha cancelada: nenhum comando de conexao e executado.
mkdir -p "$test_root/discover-cancel"
TEST_SAVED=1 TEST_DMENU_ACTION=discover TEST_WIFI_PASSWORD='' \
    run_case discover-cancel bash
grep -q $'^Senha do Wi-Fi para NeighborNet\t' \
    "$test_root/discover-cancel/dmenu.log"
! grep -q '^device wifi connect' \
    "$test_root/discover-cancel/nmcli-commands.log"

# Falha de autenticacao: nenhuma rede conectada.
mkdir -p "$test_root/discover-fail"
TEST_SAVED=1 TEST_DMENU_ACTION=discover TEST_WIFI_PASSWORD='errada' \
    TEST_WIFI_CONNECT_FAIL=1 run_case discover-fail bash
[[ ! -e "$test_root/discover-fail/connected-ssid" ]]

printf 'wifi-menu simulated: ok\n'
