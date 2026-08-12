#!/usr/bin/env bash
set -Eeuo pipefail

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

if [[ "$prompt" == PIN\ * || "$prompt" == Digite\ * ]]; then
    printf '%s\n' "${TEST_DMENU_PIN:-0000}"
    exit 0
fi

if [[ "$prompt" == Bluetooth ]]; then
    if [[ "${TEST_DMENU_ACTION:-connect}" == back && -f "$state_dir/main-menu-seen" ]]; then
        exit 0
    fi
    if [[ "${TEST_DMENU_CONFIRM:-1}" == back && -f "$state_dir/confirm-back" ]]; then
        exit 0
    fi
    : >"$state_dir/main-menu-seen"
    if grep -q 'Ativar Bluetooth' <<<"$input"; then
        grep 'Ativar Bluetooth' <<<"$input" | head -n 1
    else
        if grep -q 'Gerenciar:' <<<"$input"; then
            grep 'Gerenciar:' <<<"$input" | sed -n "${TEST_DMENU_PICK:-1}p"
        else
            grep 'Conectar novo dispositivo' <<<"$input" | head -n 1
        fi
    fi
    exit 0
fi
if [[ "${TEST_DMENU_CANCEL:-0}" == 1 ]]; then
    exit 0
fi
if [[ "$prompt" == *' > Esquecer?' ]]; then
    if [[ "${TEST_DMENU_CONFIRM:-1}" == 1 ]]; then
        grep 'Confirmar esquecimento' <<<"$input" | head -n 1
    elif [[ "${TEST_DMENU_CONFIRM:-1}" == back ]]; then
        : >"$state_dir/confirm-back"
        grep 'Voltar' <<<"$input" | head -n 1
    fi
    exit 0
fi
if [[ "$prompt" == 'Bluetooth > Conectar novo dispositivo' ]]; then
    if grep -q 'Simulated ' <<<"$input"; then
        grep 'Simulated ' <<<"$input" | head -n 1
    else
        sleep 30
    fi
    exit 0
fi
if [[ "$prompt" == Bluetooth\ \>\ * ]]; then
    if [[ "${TEST_DMENU_CONFIRM:-1}" == back && -f "$state_dir/confirm-back" ]]; then
        printf 'Voltar\n'
    elif [[ "${TEST_DMENU_ACTION:-connect}" == forget ]]; then
        grep 'Esquecer dispositivo' <<<"$input" | head -n 1
    elif [[ "${TEST_DMENU_CONFIRM:-1}" == back || "${TEST_DMENU_ACTION:-connect}" == back ]]; then
        if [[ -f "$state_dir/confirm-back" ]]; then
            printf 'Voltar\n'
        else
            : >"$state_dir/manage-back"
            printf 'Voltar\n'
        fi
    else
        head -n 1 <<<"$input"
    fi
    exit 0
fi
if grep -q 'Simulated ' <<<"$input"; then
    grep 'Simulated ' <<<"$input" | head -n 1
    exit 0
fi

sleep 30
