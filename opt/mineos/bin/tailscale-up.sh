#!/usr/bin/env bash
#
# /opt/mineos/bin/tailscale-up.sh
#
# mineOS - Attivazione Tailscale al primo boot (idempotente)
# ----------------------------------------------------------
# Legge una auth key da /opt/mineos/config/tailscale.key (se presente e non
# vuota) ed esegue 'tailscale up --authkey=...'. Logga in
# /opt/mineos/logs/tailscale.log. Se la chiave non esiste, esce SENZA errori.
# Se il nodo e' gia' connesso, non rifa' 'up' (idempotente).
#
# Non fa MAI fallire il boot: qualsiasi problema e' loggato e ignorato.
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh" 2>/dev/null || {
    MINEOS_ROOT="/opt/mineos"; MINEOS_CONFIG="${MINEOS_ROOT}/config"; MINEOS_LOGS="${MINEOS_ROOT}/logs"
}

KEYFILE="${MINEOS_CONFIG}/tailscale.key"
TS_LOG="${MINEOS_LOGS}/tailscale.log"
HOSTNAME_TS="$(hostname -s 2>/dev/null || echo mineos-rig)"

mkdir -p "${MINEOS_LOGS}" 2>/dev/null || true
tlog() { printf '%s %s\n' "$(date --iso-8601=seconds 2>/dev/null || date)" "$*" >> "${TS_LOG}" 2>/dev/null || true; }

main() {
    if ! command -v tailscale >/dev/null 2>&1; then
        tlog "tailscale non installato: salto."
        exit 0
    fi

    # Il demone deve girare (abilitato in fase di build; lo avviamo se serve).
    if command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet tailscaled || systemctl start tailscaled 2>/dev/null || true
    fi

    if [[ ! -s "${KEYFILE}" ]]; then
        tlog "Nessuna auth key in ${KEYFILE}: salto attivazione (Tailscale resta pronto ma non connesso)."
        exit 0
    fi

    # Idempotente: se gia' loggato/connesso, non rifare 'up'.
    if tailscale status >/dev/null 2>&1; then
        tlog "Tailscale gia' attivo/connesso: nessuna azione."
        exit 0
    fi

    local key; key="$(tr -d ' \t\r\n' < "${KEYFILE}")"
    if [[ -z "${key}" ]]; then
        tlog "Auth key vuota dopo sanitizzazione: salto."
        exit 0
    fi

    tlog "Attivo Tailscale (hostname=${HOSTNAME_TS})..."
    if tailscale up --authkey="${key}" --hostname="${HOSTNAME_TS}" --ssh >>"${TS_LOG}" 2>&1; then
        tlog "Tailscale connesso. IP: $(tailscale ip -4 2>/dev/null | tr '\n' ' ')"
    else
        tlog "AVVISO: 'tailscale up' fallito (authkey scaduta/errata?). Boot non interrotto."
    fi
    exit 0
}

main "$@"
