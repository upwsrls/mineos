#!/usr/bin/env bash
#
# /opt/mineos/bin/watchdog.sh
#
# mineOS - Watchdog
# -----------------
# Daemon avviato da mineos-watchdog.service. In loop continuo:
#   1. HASHRATE: interroga l'API HTTP del miner (porta da state/agent.env).
#      Se l'hashrate resta sotto soglia / a zero oltre il grace period -> restart.
#   2. TEMPERATURA: legge la temp GPU max. Sopra soglia -> warning; sopra soglia
#      critica -> shutdown protettivo dell'hardware.
#   3. GPU HUNG: se nvidia-smi/rocm-smi non risponde (timeout/errore) -> reboot.
#   4. ESCALATION: prima prova a riavviare il miner; se i restart non bastano,
#      riavvia l'intero sistema.
#
# Robusto 24/7: ogni controllo degrada con grazia (se non riesce a leggere un
# dato, logga e continua, senza azioni distruttive su dati incerti).
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

AGENT_ENV="${MINEOS_STATE}/agent.env"
AGENT_SERVICE="mineos-agent.service"

# --- Parametri di loop / soglie (override-abili da rig.conf) -----------------
POLL_INTERVAL_SEC=30        # ogni quanto controlla
ZERO_GRACE_SEC=300          # quanto tollerare hashrate ~0 prima di agire
TEMP_LIMIT_C=75             # soglia warning
TEMP_CRITICAL_C=90          # soglia shutdown protettivo
HASHRATE_MIN=0              # H/s minimi accettabili (0 = solo "non zero")
MAX_RESTARTS_BEFORE_REBOOT=3   # restart consecutivi prima di rebootare
GPU_HUNG_STRIKES=3          # letture GPU fallite consecutive prima del reboot

# Stato runtime (in memoria, è un daemon)
low_since=0                 # epoch da cui l'hashrate è sotto soglia (0 = ok)
restart_count=0            # restart consecutivi senza recupero
gpu_hung_count=0

# ----------------------------------------------------------------------------
# Carica soglie da rig.conf se presenti (sovrascrive i default).
# ----------------------------------------------------------------------------
load_thresholds() {
    [[ -f "${MINEOS_CONFIG}/rig.conf" ]] || return 0
    # shellcheck disable=SC1090
    source "${MINEOS_CONFIG}/rig.conf"
    [[ -n "${GPU_TEMP_LIMIT_C:-}"        ]] && TEMP_LIMIT_C="${GPU_TEMP_LIMIT_C}"
    [[ -n "${WATCHDOG_ZERO_GRACE_SEC:-}" ]] && ZERO_GRACE_SEC="${WATCHDOG_ZERO_GRACE_SEC}"
    [[ -n "${WATCHDOG_HASHRATE_MIN:-}"   ]] && HASHRATE_MIN="${WATCHDOG_HASHRATE_MIN}"
}

# ----------------------------------------------------------------------------
# Lettura hashrate dall'API del miner (best effort, ritorna H/s intero)
# Stampa "-1" se non è possibile leggere (così non scatta un falso allarme).
# ----------------------------------------------------------------------------
read_hashrate() {
    [[ -f "$AGENT_ENV" ]] || { echo "-1"; return; }
    # shellcheck disable=SC1090
    source "$AGENT_ENV"
    local url body hr="-1"
    case "${API_TYPE:-}" in
        trex)     url="http://127.0.0.1:${API_PORT}/summary" ;;
        lolminer) url="http://127.0.0.1:${API_PORT}/" ;;
        srbminer) url="http://127.0.0.1:${API_PORT}/" ;;
        *)        echo "-1"; return ;;
    esac
    body="$(curl -fsS --max-time 5 "$url" 2>/dev/null)" || { echo "-1"; return; }

    if command -v jq >/dev/null 2>&1; then
        case "${API_TYPE}" in
            trex)     hr="$(echo "$body" | jq -r '.hashrate // -1' 2>/dev/null)" ;;
            lolminer) hr="$(echo "$body" | jq -r '[.Session?.Performance_Summary, (.Workers // [] | map(.Performance) | add)] | map(select(.!=null)) | first // -1' 2>/dev/null)" ;;
            srbminer) hr="$(echo "$body" | jq -r '.algorithms[0].hashrate.total[0] // -1' 2>/dev/null)" ;;
        esac
    else
        # Fallback grezzo: estrae il primo numero associato a "hashrate".
        hr="$(echo "$body" | grep -oE '"hashrate"[^0-9]*[0-9]+' | grep -oE '[0-9]+' | head -1)"
        [[ -z "$hr" ]] && hr="-1"
    fi
    # Normalizza a intero.
    hr="${hr%%.*}"
    [[ "$hr" =~ ^-?[0-9]+$ ]] || hr="-1"
    echo "$hr"
}

# ----------------------------------------------------------------------------
# Lettura temperatura GPU massima (best effort). Stampa "-1" se non leggibile.
# ----------------------------------------------------------------------------
read_gpu_temp_max() {
    local vendor="${GPU_VENDOR:-$(detect_gpu_vendor)}"
    local t max=-1
    if [[ "$vendor" == "nvidia" || "$vendor" == "both" ]] && command -v nvidia-smi >/dev/null; then
        while read -r t; do
            [[ "$t" =~ ^[0-9]+$ ]] || continue
            (( t > max )) && max="$t"
        done < <(timeout 8 nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null)
    fi
    if [[ "$vendor" == "amd" || "$vendor" == "both" ]] && command -v rocm-smi >/dev/null; then
        while read -r t; do
            t="${t%%.*}"
            [[ "$t" =~ ^[0-9]+$ ]] || continue
            (( t > max )) && max="$t"
        done < <(timeout 8 rocm-smi --showtemp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' )
    fi
    echo "$max"
}

# ----------------------------------------------------------------------------
# Rilevamento GPU hung: nvidia-smi/rocm-smi che non risponde -> errore.
# Ritorna 0 se GPU OK, 1 se hung/non interrogabile.
# ----------------------------------------------------------------------------
check_gpu_alive() {
    local vendor="${GPU_VENDOR:-$(detect_gpu_vendor)}"
    case "$vendor" in
        nvidia|both)
            command -v nvidia-smi >/dev/null || return 0
            timeout 10 nvidia-smi >/dev/null 2>&1 && return 0 || return 1 ;;
        amd)
            command -v rocm-smi >/dev/null || return 0
            timeout 10 rocm-smi >/dev/null 2>&1 && return 0 || return 1 ;;
        *) return 0 ;;
    esac
}

# ----------------------------------------------------------------------------
# Azioni
# ----------------------------------------------------------------------------
restart_miner() {
    log WARN "Watchdog: restart del miner ($AGENT_SERVICE). Tentativo #$((restart_count+1))."
    sysctl_safe restart "$AGENT_SERVICE"
    restart_count=$((restart_count+1))
    low_since=0
}

reboot_system() {
    log ERROR "Watchdog: condizione grave -> REBOOT del sistema. Motivo: $*"
    # Marca il motivo per diagnosi post-reboot.
    echo "$(date --iso-8601=seconds) reboot: $*" >> "${MINEOS_STATE}/reboot-reasons.log"
    notify REBOOT "Reboot automatico del rig. Motivo: $*"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log WARN "DRY_RUN: reboot simulato."
        return 0
    fi
    sync
    systemctl reboot || reboot
}

shutdown_system() {
    log ERROR "Watchdog: shutdown protettivo. Motivo: $*"
    echo "$(date --iso-8601=seconds) shutdown: $*" >> "${MINEOS_STATE}/reboot-reasons.log"
    notify SHUTDOWN "Shutdown protettivo del rig. Motivo: $*"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log WARN "DRY_RUN: shutdown simulato."
        return 0
    fi
    sync
    systemctl poweroff || poweroff
}

# ----------------------------------------------------------------------------
# Un ciclo di controllo
# ----------------------------------------------------------------------------
check_once() {
    # Se l'agent non è attivo (es. reboot-required, stop manuale), non allarmare.
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-active --quiet "$AGENT_SERVICE"; then
            log INFO "Agent non attivo: watchdog in pausa logica."
            low_since=0; return 0
        fi
    fi

    # --- GPU hung ---
    if ! check_gpu_alive; then
        gpu_hung_count=$((gpu_hung_count+1))
        log ERROR "GPU non risponde (strike $gpu_hung_count/$GPU_HUNG_STRIKES)."
        if (( gpu_hung_count >= GPU_HUNG_STRIKES )); then
            reboot_system "GPU hung (nvidia-smi/rocm-smi non risponde)"
        fi
        return 0
    else
        gpu_hung_count=0
    fi

    # --- Temperatura ---
    local temp; temp="$(read_gpu_temp_max)"
    if [[ "$temp" != "-1" ]]; then
        log INFO "GPU temp max: ${temp}C (limit=${TEMP_LIMIT_C} crit=${TEMP_CRITICAL_C})."
        if (( temp >= TEMP_CRITICAL_C )); then
            notify HIGH_TEMP "Temperatura critica: ${temp}C >= ${TEMP_CRITICAL_C}C. Avvio shutdown protettivo."
            shutdown_system "Temperatura critica ${temp}C >= ${TEMP_CRITICAL_C}C"
            return 0
        elif (( temp >= TEMP_LIMIT_C )); then
            log WARN "Temperatura alta: ${temp}C >= ${TEMP_LIMIT_C}C (monitoro)."
        fi
    fi

    # --- Hashrate ---
    local hr; hr="$(read_hashrate)"
    if [[ "$hr" == "-1" ]]; then
        log WARN "Hashrate non leggibile (API non pronta?). Nessuna azione."
        return 0
    fi
    log INFO "Hashrate corrente: ${hr} H/s (min=${HASHRATE_MIN})."

    local now; now="$(date +%s)"
    if (( hr <= HASHRATE_MIN )); then
        if (( low_since == 0 )); then
            low_since="$now"
            log WARN "Hashrate sotto soglia: avvio timer grace (${ZERO_GRACE_SEC}s)."
        elif (( now - low_since >= ZERO_GRACE_SEC )); then
            log ERROR "Hashrate sotto soglia da $((now - low_since))s: intervengo."
            notify LOW_HASHRATE "Hashrate ${hr} H/s sotto soglia (${HASHRATE_MIN}) da $((now - low_since))s. Intervengo."
            if (( restart_count >= MAX_RESTARTS_BEFORE_REBOOT )); then
                reboot_system "Hashrate basso persistente dopo $restart_count restart"
            else
                restart_miner
            fi
        fi
    else
        # Recupero: azzera i contatori.
        if (( low_since != 0 || restart_count != 0 )); then
            log INFO "Hashrate recuperato: azzero contatori."
        fi
        low_since=0
        restart_count=0
    fi
}

# ----------------------------------------------------------------------------
# MAIN loop
# ----------------------------------------------------------------------------
main() {
    require_root
    load_thresholds
    [[ -n "${POLL_INTERVAL_SEC}" ]] || POLL_INTERVAL_SEC=30
    log INFO "Watchdog avviato (poll=${POLL_INTERVAL_SEC}s grace=${ZERO_GRACE_SEC}s temp_limit=${TEMP_LIMIT_C} crit=${TEMP_CRITICAL_C})."

    # Stop pulito sui segnali di systemd.
    trap 'log INFO "Watchdog: stop richiesto."; exit 0' SIGTERM SIGINT

    while true; do
        # Un errore in un singolo ciclo non deve uccidere il daemon.
        check_once || log WARN "Errore non fatale nel ciclo di watchdog."
        sleep "${POLL_INTERVAL_SEC}"
    done
}

main "$@"
