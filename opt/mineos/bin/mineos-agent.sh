#!/usr/bin/env bash
#
# /opt/mineos/bin/mineos-agent.sh
#
# mineOS - Mining agent
# ---------------------
# Avviato da systemd (mineos-agent.service). Compiti:
#   1. Carica rig.conf / wallet.conf / pools.conf.
#   2. Applica (opzionale) power limit / overclock GPU.
#   3. Costruisce la riga di comando del miner scelto (trex/lolminer/srbminer),
#      abilitando l'API HTTP locale che il watchdog interroga per l'hashrate.
#   4. Lancia il miner in foreground e gestisce il GRACEFUL SHUTDOWN
#      (inoltra SIGTERM/SIGINT al processo figlio e attende che chiuda).
#   5. Logga in modo strutturato (via common.sh -> journald + file).
#
# Pensato per uso 24/7: nessun comando rischioso, fallisce in modo esplicito,
# scrive in state/agent.env i parametri che servono al watchdog.
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# Porte API locali (una per miner; sempre bind su loopback).
API_PORT_TREX=4067
API_PORT_LOL=4068
API_PORT_SRB=4069

MINER_PID=""          # PID del processo miner figlio
AGENT_ENV="${MINEOS_STATE}/agent.env"   # consumato dal watchdog

# ----------------------------------------------------------------------------
# Caricamento configurazione
# ----------------------------------------------------------------------------
load_all_conf() {
    # Pre-check con messaggio azionabile: se manca la config, il first boot non
    # ha completato. Meglio un errore chiaro che un 'source' criptico.
    local missing=0 f
    for f in rig.conf wallet.conf pools.conf; do
        [[ -f "${MINEOS_CONFIG}/${f}" ]] || { log ERROR "Config mancante: ${MINEOS_CONFIG}/${f}"; missing=1; }
    done
    if [[ "$missing" -eq 1 ]]; then
        die "Configurazione mineOS incompleta. Esegui il first boot: bash /opt/mineos/bin/first-boot-setup.sh"
    fi

    load_conf "${MINEOS_CONFIG}/rig.conf"
    load_conf "${MINEOS_CONFIG}/wallet.conf"
    load_conf "${MINEOS_CONFIG}/pools.conf"

    # Validazioni minime: meglio fallire subito che minare "a vuoto".
    : "${MINER:?MINER non definito in rig.conf}"
    : "${ALGO:?ALGO non definito in rig.conf}"
    : "${POOL_URL:?POOL_URL non definito in pools.conf}"
    : "${POOL_USER:?POOL_USER non definito in pools.conf}"
    : "${POOL_PASS:=x}"
    : "${GPU_VENDOR:=$(detect_gpu_vendor)}"
    : "${GPU_POWER_LIMIT_W:=0}"
    : "${GPU_CORE_OFFSET:=0}"
    : "${GPU_MEM_OFFSET:=0}"
    # Payout (da wallet.conf): MANUALE dalla dashboard Kryptex (default).
    : "${PAYOUT_MODE:=manual}"

    # Normalizza l'algoritmo: i miner rifiutano i ticker (es. 'PRL'/'RVN').
    # Difensivo anche per rig.conf già scritti con un valore errato (niente
    # bisogno di rieditare il file: la correzione avviene al caricamento).
    local algo_in="$ALGO"
    ALGO="$(normalize_algo "$ALGO")"
    [[ "$algo_in" != "$ALGO" ]] && log WARN "Algoritmo '${algo_in}' normalizzato in '${ALGO}'."

    # Pearl/pearlhash richiede SRBMiner: corregge rig.conf scritti con MINER=trex.
    local miner_in="$MINER"
    MINER="$(resolve_miner_for_algo "$MINER" "$ALGO")"
    [[ "$miner_in" != "$MINER" ]] && log WARN "Miner '${miner_in}' incompatibile con '${ALGO}': uso '${MINER}'."

    log INFO "Config caricata: miner=$MINER algo=$ALGO pool=$POOL_URL user=$POOL_USER payout=${PAYOUT_MODE} (prelievi dalla dashboard Kryptex)"
}

# Estrae host:porta da un URL tipo stratum+tcp://host:porta (per i miner che
# vogliono pool senza schema).
pool_hostport() {
    echo "${POOL_URL#*://}"
}

# ----------------------------------------------------------------------------
# Overclock / power limit (best effort, non blocca il mining se fallisce)
# ----------------------------------------------------------------------------
apply_nvidia_tuning() {
    command -v nvidia-smi >/dev/null || return 0
    local oc_script="${MINEOS_BIN}/apply-gpu-oc.sh"
    if [[ -x "$oc_script" && -f "${MINEOS_CONFIG}/gpu-oc.conf" ]]; then
        # shellcheck disable=SC1090
        source "${MINEOS_CONFIG}/gpu-oc.conf" 2>/dev/null || true
        if [[ "${GPU_AUTO_OC:-false}" == "true" ]]; then
            log INFO "OC NVIDIA: delego a apply-gpu-oc.sh (profili Pearl/pearlhash)."
            run bash "$oc_script" || log WARN "apply-gpu-oc.sh fallito (proseguo mining)."
            return 0
        fi
    fi
    # Fallback: tuning base da rig.conf (senza gpu-oc.conf).
    run nvidia-smi -pm 1 || log WARN "nvidia-smi -pm 1 fallito."
    if [[ "${GPU_POWER_LIMIT_W}" != "0" ]]; then
        log INFO "Imposto power limit NVIDIA a ${GPU_POWER_LIMIT_W}W"
        run nvidia-smi -pl "${GPU_POWER_LIMIT_W}" || log WARN "Power limit non applicato."
    fi
    # OC core/mem via clock offset (richiede coolbits/driver recenti).
    if [[ "${GPU_CORE_OFFSET}" != "0" || "${GPU_MEM_OFFSET}" != "0" ]]; then
        log INFO "OC NVIDIA core=${GPU_CORE_OFFSET} mem=${GPU_MEM_OFFSET} (best effort)."
        # L'API esatta dipende dal driver; lasciamo l'OC fine ad uno step separato.
    fi
}

apply_amd_tuning() {
    command -v rocm-smi >/dev/null || return 0
    if [[ "${GPU_POWER_LIMIT_W}" != "0" ]]; then
        log INFO "Imposto power cap AMD a ${GPU_POWER_LIMIT_W}W (best effort)."
        run rocm-smi --setpoweroverdrive "${GPU_POWER_LIMIT_W}" || log WARN "Power cap AMD non applicato."
    fi
}

apply_tuning() {
    case "${GPU_VENDOR}" in
        nvidia) apply_nvidia_tuning ;;
        amd)    apply_amd_tuning ;;
        both)   apply_nvidia_tuning; apply_amd_tuning ;;
    esac
}

# ----------------------------------------------------------------------------
# Localizzazione binario del miner
# ----------------------------------------------------------------------------
miner_dir() { echo "${MINEOS_MINERS}/${MINER}/current"; }

find_miner_binary() {
    local base="${MINEOS_MINERS}/${MINER}"
    local dir; dir="$(miner_dir)"

    # Fallback: se 'current' manca o è rotto, usa la versione più recente.
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        dir="$(find -L "$base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -V | tail -1)"
    fi
    [[ -d "$dir" || -L "$dir" ]] \
        || die "Miner '$MINER' non installato (manca ${base}). Esegui: update-mineos.sh --miners"

    local bin
    bin="$(find_miner_binary_in_dir "$MINER" "$dir")" \
        || die "Binario del miner '$MINER' non trovato/eseguibile in ${dir}. Reinstalla con: update-mineos.sh --miners"
    echo "$bin"
}

# ----------------------------------------------------------------------------
# Costruzione argomenti per miner + scrittura agent.env per il watchdog
# ----------------------------------------------------------------------------
build_args() {
    # Utente stratum per questo segmento (default: utente reale; per la dev fee
    # viene passato l'account del creatore). Vedi rotazione in main().
    local seg_user="${1:-$POOL_USER}"
    local hostport; hostport="$(pool_hostport)"
    case "$MINER" in
        trex)
            API_PORT="$API_PORT_TREX"; API_TYPE="trex"
            MINER_ARGS=(
                -a "$ALGO"
                -o "$POOL_URL"
                -u "$seg_user"
                -p "$POOL_PASS"
                --api-bind-http "127.0.0.1:${API_PORT}"
                # Riavvio interno disattivato: la gestione restart la fa systemd/watchdog.
                --no-watchdog
            )
            ;;
        lolminer)
            API_PORT="$API_PORT_LOL"; API_TYPE="lolminer"
            MINER_ARGS=(
                --algo "$ALGO"
                --pool "$hostport"
                --user "$seg_user"
                --pass "$POOL_PASS"
                --apiport "$API_PORT"
            )
            ;;
        srbminer)
            API_PORT="$API_PORT_SRB"; API_TYPE="srbminer"
            # --disable-cpu: rig GPU, evitiamo il mining CPU (come da comando
            # ufficiale Kryptex per pearlhash/Pearl e in generale per i rig GPU).
            MINER_ARGS=(
                --algorithm "$ALGO"
                --pool "$hostport"
                --wallet "$seg_user"
                --password "$POOL_PASS"
                --disable-cpu
                --api-enable
                --api-port "$API_PORT"
            )
            ;;
        *) die "Miner non supportato: $MINER" ;;
    esac

    # Pubblica per il watchdog come interrogare l'API e quali soglie usare.
    umask 077
    cat > "$AGENT_ENV" <<EOF
API_TYPE="${API_TYPE}"
API_PORT="${API_PORT}"
MINER="${MINER}"
GPU_VENDOR="${GPU_VENDOR}"
EOF
    log INFO "agent.env scritto (api_type=$API_TYPE port=$API_PORT)."
}

# ----------------------------------------------------------------------------
# Graceful shutdown
# ----------------------------------------------------------------------------
graceful_stop() {
    log INFO "Segnale di stop ricevuto: chiusura graceful del miner (pid=${MINER_PID:-n/a})."
    if [[ -n "$MINER_PID" ]] && kill -0 "$MINER_PID" 2>/dev/null; then
        # Chiediamo prima una chiusura pulita (SIGINT, molti miner lo gestiscono).
        kill -INT "$MINER_PID" 2>/dev/null || true
        # Attendi fino a 30s, poi forza.
        for _ in $(seq 1 30); do
            kill -0 "$MINER_PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$MINER_PID" 2>/dev/null; then
            log WARN "Miner non chiuso entro 30s: invio SIGKILL."
            kill -KILL "$MINER_PID" 2>/dev/null || true
        fi
    fi
    # Pulisce lo stato pubblicato.
    rm -f "$AGENT_ENV" 2>/dev/null || true
    log INFO "Agent terminato."
    exit 0
}

# ----------------------------------------------------------------------------
# Esecuzione di un SEGMENTO di mining (durata limitata, interrompibile).
# Lancia il miner con l'utente stratum dato e resta attivo per <seconds>.
# Ritorna:
#   0   segmento completato regolarmente (tempo scaduto)
#   1   il miner è uscito da solo prima dello scadere (errore) -> restart
# I segnali SIGTERM/SIGINT sono gestiti dal trap graceful_stop (esce subito).
# ----------------------------------------------------------------------------
run_segment() {
    local label="$1" seg_user="$2" seconds="$3" bin="$4"
    build_args "$seg_user"

    "$bin" "${MINER_ARGS[@]}" &
    MINER_PID=$!
    log INFO "[$label] miner avviato pid=$MINER_PID user=${seg_user} per ${seconds}s."

    # Attesa a piccoli passi: reattiva ai segnali e rileva crash del miner.
    local elapsed=0 step=5
    while (( elapsed < seconds )); do
        if ! kill -0 "$MINER_PID" 2>/dev/null; then
            wait "$MINER_PID" 2>/dev/null; local rc=$?
            log WARN "[$label] miner uscito (rc=$rc) dopo ${elapsed}s. systemd/riavvio gestiranno."
            return 1
        fi
        sleep "$step"
        elapsed=$(( elapsed + step ))
    done

    # Fine segmento: chiusura pulita del miner prima del prossimo.
    if kill -0 "$MINER_PID" 2>/dev/null; then
        kill -INT "$MINER_PID" 2>/dev/null || true
        local w=0
        while (( w < 30 )) && kill -0 "$MINER_PID" 2>/dev/null; do sleep 1; w=$(( w + 1 )); done
        kill -0 "$MINER_PID" 2>/dev/null && kill -KILL "$MINER_PID" 2>/dev/null || true
    fi
    wait "$MINER_PID" 2>/dev/null || true
    return 0
}

# ----------------------------------------------------------------------------
# MAIN
# ----------------------------------------------------------------------------
main() {
    require_root
    # Il riavvio (se richiesto) è già avvenuto: rimuovi il flag così non resta
    # appeso e non confonde watchdog/diagnostica. (Anche ExecStartPre lo fa.)
    clear_reboot_required
    mkdir -p "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true
    load_all_conf
    apply_tuning

    local bin; bin="$(find_miner_binary)"

    # Costruisce gli args per l'utente reale (pubblica agent.env per il watchdog).
    build_args "$POOL_USER"

    # Intercetta i segnali di systemd per il graceful shutdown.
    trap graceful_stop SIGTERM SIGINT

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: non avvio realmente il miner."
        exit 0
    fi

    # --- Dev fee (contributo al progetto): rotazione temporale trasparente ---
    fee_load
    local cycle_sec fee_sec user_sec fee_user=""
    cycle_sec=$(( FEE_CYCLE_MIN * 60 ))
    if fee_active; then
        fee_sec="$(fee_seconds_per_cycle)"
        user_sec=$(( cycle_sec - fee_sec ))
        (( user_sec < 0 )) && user_sec=0
        fee_user="$(fee_pool_user)"
        log INFO "Dev fee OBBLIGATORIA: ${FEE_PERCENT}% (${fee_sec}s ogni ${FEE_CYCLE_MIN}min al creatore). Mini il $((100 - FEE_PERCENT))% per te. Grazie per il supporto a mineOS."
    else
        # Fee sempre dovuta, ma FEE_ACCOUNT non impostato da chi ha buildato l'ISO:
        # la fee non e' instradabile. Va corretto fee.conf (FEE_ACCOUNT).
        fee_sec=0; user_sec="$cycle_sec"
        log WARN "Dev fee ${FEE_PERCENT}% dovuta ma FEE_ACCOUNT non configurato in fee.conf: contributo non instradabile finche' non viene impostato."
    fi

    notify MINING_START "Mining avviato: miner=${MINER} algo=${ALGO} pool=${POOL_URL} dev-fee=${FEE_PERCENT}% (obbligatoria, trasparente) (payout manuale da dashboard Kryptex)"

    # Loop a cicli: segmento utente, poi (se attiva) segmento fee.
    while true; do
        run_segment "USER" "$POOL_USER" "$user_sec" "$bin" \
            || { rm -f "$AGENT_ENV" 2>/dev/null || true; exit 1; }

        if (( fee_sec > 0 )) && [[ -n "$fee_user" ]]; then
            log INFO "[FEE] contributo progetto: ${fee_sec}s all'account del creatore (grazie!)."
            run_segment "FEE" "$fee_user" "$fee_sec" "$bin" \
                || { rm -f "$AGENT_ENV" 2>/dev/null || true; exit 1; }
        fi
    done
}

main "$@"
