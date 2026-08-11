#!/usr/bin/env bash

# Mantem o IBus alinhado ao layout XKB da sessao X11 e aplica ABNT2.
# Cada componente e opcional para permitir o uso da configuracao em hosts
# sem IBus, gsettings ou setxkbmap.

if command -v gsettings >/dev/null 2>&1; then
    gsettings set org.freedesktop.ibus.general use-system-keyboard-layout true \
        >/dev/null 2>&1 || true
    gsettings set org.freedesktop.ibus.panel show-icon-on-systray false \
        >/dev/null 2>&1 || true
fi

if command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap -model pc105 -layout br -variant abnt2 \
        >/dev/null 2>&1 || true
fi
