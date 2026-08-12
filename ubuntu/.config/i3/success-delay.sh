#!/usr/bin/env bash
# Mantém o estado "verificando…" (anel verde) visível brevemente
# antes de destravar. Chamado pelo pam_exec apenas no sucesso.
sleep 0.4
exit 0