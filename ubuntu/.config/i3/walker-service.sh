#!/usr/bin/env bash

# O Elephant pode ser iniciado pelo systemd antes da sessao X11 estar pronta.
# Nesse caso, ele fica sem DISPLAY/XAUTHORITY e as aplicacoes selecionadas no
# Walker sao registradas como ativadas, mas nao conseguem abrir uma janela.
set -u

ELEPHANT_SERVICE="elephant.service"
ELEPHANT_SOCKET="/run/user/$(id -u)/elephant/elephant.sock"
WALKER="${WALKER_BIN:-$HOME/.local/bin/walker}"

# Faz o servico receber as variaveis da sessao atual do i3.
systemctl --user import-environment \
    DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_CURRENT_DESKTOP XDG_DATA_DIRS \
    >/dev/null 2>&1 || true

# Se o servico ja subiu cedo demais no login, reinicia-lo aplica o ambiente
# grafico importado. Se ainda nao existir, inicia normalmente.
if systemctl --user is-active --quiet "$ELEPHANT_SERVICE"; then
    systemctl --user try-restart "$ELEPHANT_SERVICE" >/dev/null 2>&1 || true
else
    systemctl --user start "$ELEPHANT_SERVICE" >/dev/null 2>&1 || true
fi

# Evita que o Walker residente comece antes de o socket do Elephant existir.
for _ in $(seq 1 50); do
    [ -S "$ELEPHANT_SOCKET" ] && break
    sleep 0.1
done

exec "$WALKER" --gapplication-service
