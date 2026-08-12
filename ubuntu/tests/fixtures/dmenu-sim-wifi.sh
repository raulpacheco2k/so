#!/usr/bin/env bash
set -Eeuo pipefail

# Simula o dmenu para os prompts do wifi-menu.sh: registra prompt e itens no
# dmenu.log e responde conforme as variaveis TEST_DMENU_*.

state_dir="${TEST_STATE_DIR:?TEST_STATE_DIR is required}"
prompt=''
while (($# > 0)); do
    if [[ "$1" == '-p' ]]; then
        prompt="${2:-}"
        shift 2
    else
        shift
    fi
done

input="$(< /dev/stdin)"
printf '%s\t%s\n' "$prompt" "$input" >>"$state_dir/dmenu.log"

if [[ "$prompt" == Wi-Fi ]]; then
    if [[ -f "$state_dir/main-menu-seen" ]]; then
        exit 0
    fi
    : >"$state_dir/main-menu-seen"
    if grep -q 'Ativar Wi-Fi' <<<"$input"; then
        grep 'Ativar Wi-Fi' <<<"$input" | head -n 1
    elif grep -q 'Gerenciar:' <<<"$input"; then
        case "${TEST_DMENU_ACTION:-radio-off}" in
            disconnect)
                grep 'Desconectar de' <<<"$input" | head -n 1
                ;;
            radio-off)
                grep 'Desativar Wi-Fi' <<<"$input" | head -n 1
                ;;
            discover)
                grep 'Conectar nova rede' <<<"$input" | head -n 1
                ;;
            *)
                grep 'Gerenciar:' <<<"$input" | sed -n "${TEST_DMENU_PICK:-1}p"
                ;;
        esac
    else
        grep 'Desativar Wi-Fi' <<<"$input" | head -n 1
    fi
    exit 0
fi
if [[ "$prompt" == *' > Esquecer?' ]]; then
    if [[ "${TEST_DMENU_CONFIRM:-1}" == back ]]; then
        : >"$state_dir/confirm-back"
        grep 'Voltar' <<<"$input" | head -n 1
    else
        grep 'Confirmar esquecimento' <<<"$input" | head -n 1
    fi
    exit 0
fi
if [[ "$prompt" == 'Wi-Fi > Conectar nova rede' ]]; then
    if grep -q 'NeighborNet' <<<"$input"; then
        grep 'NeighborNet' <<<"$input" | head -n 1
    else
        sleep 30
    fi
    exit 0
fi
if [[ "$prompt" == 'Senha do Wi-Fi para '* ]]; then
    printf '%s\n' "${TEST_WIFI_PASSWORD:-}"
    exit 0
fi
if [[ "$prompt" == Wi-Fi\ \>\ * ]]; then
    if [[ -f "$state_dir/confirm-back" ]]; then
        grep 'Voltar' <<<"$input" | head -n 1
    elif [[ "${TEST_SUBMENU_ACTION:-connect}" == forget ]]; then
        grep 'Esquecer rede' <<<"$input" | head -n 1
    elif [[ "${TEST_SUBMENU_ACTION:-connect}" == back ]]; then
        grep 'Voltar' <<<"$input" | head -n 1
    else
        head -n 1 <<<"$input"
    fi
    exit 0
fi

sleep 30
