#!/usr/bin/env bash
#
# /opt/mineos/bin/apply-gpu-oc.sh
#
# mineOS - Overclock automatico multi-GPU NVIDIA (Pearl/pearlhash)
# ---------------------------------------------------------------
# Applica profili per modello (RTX 3090, GTX 1080 Ti, GTX 1080, GTX 1660...):
#   - power limit (nvidia-smi -pl)
#   - core clock lock (nvidia-smi --lock-gpu-clocks)
#   - memory clock lock (offset su max memory)
#   - ventola iniziale + curva (via gpu-fan-daemon se abilitato)
#
# Config: /opt/mineos/config/gpu-oc.conf (da gpu-oc.conf.example)
#
# Uso:
#   sudo /opt/mineos/bin/apply-gpu-oc.sh
#   sudo /opt/mineos/bin/apply-gpu-oc.sh --dry-run
#   sudo /opt/mineos/bin/apply-gpu-oc.sh --reset
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

OC_CONF="${MINEOS_CONFIG}/gpu-oc.conf"
RESET=0

for arg in "$@"; do
    case "$arg" in
        --dry-run) export DRY_RUN=1 ;;
        --reset)   RESET=1 ;;
        --help|-h)
            cat <<'EOF'
Uso: sudo apply-gpu-oc.sh [--dry-run] [--reset]

  --reset    ripristina clock/potenza default NVIDIA
EOF
            exit 0
            ;;
        *) die "Argomento sconosciuto: $arg (usa --help)" ;;
    esac
done

# nvidia-smi/timeout: OGNI chiamata a nvidia-smi passa da qui, con timeout, cosi'
# un driver appeso non blocca lo script (che a sua volta bloccherebbe systemd).
NSMI_TIMEOUT=15
nsmi() { timeout "${NSMI_TIMEOUT}" nvidia-smi "$@"; }

# Il profilo con questa MODEL_KEY esiste in PROFILES?
profile_exists() {
    local want="$1" line kk
    for line in "${PROFILES[@]:-}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r kk _ <<< "$line"
        [[ "$kk" == "$want" ]] && return 0
    done
    return 1
}

# Match nome GPU (da nvidia-smi) -> MODEL_KEY, ROBUSTO e con match parziale.
# Normalizza il nome (rimuove 'NVIDIA'/'GeForce', punteggiatura, spazi), estrae
# famiglia (rtx/gtx), numero modello (3-4 cifre) e suffisso (ti/super), quindi
# prova in ordine: chiave esatta -> senza suffisso -> generazione generica (es.
# rtx_50xx) -> default. Logga SEMPRE la chiave scelta e i candidati (BUG1).
gpu_model_key() {
    local raw="$1" n fam="" num="" suf=""
    n=" ${raw,,} "
    n="${n//nvidia/ }"; n="${n//geforce/ }"; n="${n//,/ }"; n="${n//-/ }"
    n=" $(printf '%s' "$n" | tr -s ' \t' '  ' | sed 's/^ *//;s/ *$//') "
    case "$n" in
        *rtx*) fam="rtx" ;;
        *gtx*) fam="gtx" ;;
        *)     fam="gpu" ;;
    esac
    num="$(printf '%s' "$n" | grep -oE '[0-9]{3,4}' | head -1)"
    [[ "$n" == *" super "* || "$n" == *super* ]] && suf="super"
    [[ "$n" == *" ti "* ]] && suf="ti"

    local -a cands=()
    if [[ -n "$num" ]]; then
        [[ -n "$suf" ]] && cands+=( "${fam}_${num}_${suf}" )
        cands+=( "${fam}_${num}" )
        # generazione generica: prime 2 cifre + xx (5080->50xx, 1660->16xx, 1080->10xx)
        [[ ${#num} -eq 4 ]] && cands+=( "${fam}_${num:0:2}xx" )
    fi
    cands+=( "default" )

    local c
    for c in "${cands[@]}"; do
        if profile_exists "$c"; then
            log INFO "OC match: GPU '${raw}' -> profilo '${c}' (candidati provati: ${cands[*]})."
            printf '%s' "$c"; return 0
        fi
    done
    log WARN "OC match: GPU '${raw}' senza profilo (nemmeno 'default'!). Uso 'default'."
    printf 'default'
}

# Carica profilo MODEL_KEY -> variabili PL_W, CORE_MHZ, MEM_OFF, TEMP_TARGET, ...
load_profile() {
    local key="$1"
    PL_W="" CORE_MHZ="" MEM_OFF="" TEMP_TARGET=""
    FAN_MIN="" FAN_MAX="" TEMP_LO="" TEMP_HI=""
    local line k
    for line in "${PROFILES[@]:-}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r k PL_W CORE_MHZ MEM_OFF TEMP_TARGET FAN_MIN FAN_MAX TEMP_LO TEMP_HI <<< "$line"
        [[ "$k" == "$key" ]] && return 0
    done
    # Fallback default
    for line in "${PROFILES[@]:-}"; do
        [[ -z "$line" ]] && continue
        IFS='|' read -r k PL_W CORE_MHZ MEM_OFF TEMP_TARGET FAN_MIN FAN_MAX TEMP_LO TEMP_HI <<< "$line"
        [[ "$k" == "default" ]] && return 0
    done
    return 1
}

# Interpolazione lineare fan % in base a temperatura.
fan_percent_for_temp() {
    local temp="$1" lo="$2" hi="$3" fmin="$4" fmax="$5"
    awk -v t="$temp" -v lo="$lo" -v hi="$hi" -v fmin="$fmin" -v fmax="$fmax" \
        'BEGIN{
            if (t+0 <= lo+0) { printf "%d", fmin; exit }
            if (t+0 >= hi+0) { printf "%d", fmax; exit }
            pct=fmin + (t-lo)*(fmax-fmin)/(hi-lo)
            if (pct<fmin) pct=fmin; if (pct>fmax) pct=fmax
            printf "%d", pct+0.5
        }'
}

load_oc_conf() {
    GPU_AUTO_OC="true"
    FAN_DAEMON="true"
    FAN_POLL_SEC="15"
    OC_ALGO="pearlhash"
    # pearlhash e' COMPUTE-BOUND: comanda il CORE CLOCK, la memoria e' irrilevante.
    # Strategia: NON lockare mai il core (lasciar fare il boost), MEM_OFFSET=0,
    # gestire solo il POWER LIMIT + curva ventole. I campi CORE_MHZ/MEM_OFFSET
    # restano nel formato per compatibilita' ma sono SEMPRE 0 e NON applicati.
    # Formato: KEY|PL_W|CORE_MHZ|MEM_OFF|TEMP_TARGET|FAN_MIN|FAN_MAX|TEMP_LO|TEMP_HI
    # PL_W=0 => lascia il default del driver (non forzare: 100W su una 5080 viene
    # rifiutato). Valori PL da misure sul campo.
    PROFILES=(
        "rtx_5090|450|0|0|70|40|100|55|75"
        "rtx_5080|360|0|0|69|40|100|55|74"
        "rtx_5070|250|0|0|68|40|100|54|72"
        "rtx_50xx|300|0|0|70|40|100|55|75"
        "rtx_4090|350|0|0|66|40|100|52|72"
        "rtx_4080|300|0|0|66|40|100|52|72"
        "rtx_4070|200|0|0|64|40|100|50|70"
        "rtx_40xx|280|0|0|66|40|100|52|72"
        "rtx_3090|350|0|0|72|45|100|58|76"
        "rtx_3080|300|0|0|70|45|100|56|74"
        "rtx_30xx|300|0|0|70|45|100|56|74"
        "gtx_1660_super|65|0|0|62|35|95|48|68"
        "gtx_1660_ti|65|0|0|62|35|95|48|68"
        "gtx_1660|60|0|0|62|35|95|48|68"
        "gtx_16xx|65|0|0|62|35|95|48|68"
        "gtx_1080_ti|180|0|0|68|40|100|54|72"
        "gtx_1080|150|0|0|66|40|100|52|70"
        "gtx_10xx|150|0|0|66|40|100|52|70"
        "default|0|0|0|70|40|100|55|78"
    )
    if [[ -f "$OC_CONF" ]]; then
        # shellcheck disable=SC1090
        source "$OC_CONF"
    elif [[ -f "${MINEOS_CONFIG}/gpu-oc.conf.example" ]]; then
        log WARN "gpu-oc.conf assente: uso gpu-oc.conf.example."
        # shellcheck disable=SC1090
        source "${MINEOS_CONFIG}/gpu-oc.conf.example"
    else
        log WARN "gpu-oc.conf assente: uso profili incorporati."
    fi
}

reset_gpu() {
    local idx="$1"
    log INFO "GPU ${idx}: reset clock/potenza default."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then return 0; fi
    nsmi -i "$idx" --reset-gpu-clocks    >/dev/null 2>&1 || true
    nsmi -i "$idx" --reset-memory-clocks >/dev/null 2>&1 || true
    nsmi -i "$idx" -rac                   >/dev/null 2>&1 || true
}

apply_one_gpu() {
    local idx="$1" name="$2" key
    key="$(gpu_model_key "$name")"
    load_profile "$key" || { log WARN "GPU ${idx} (${name}): profilo non trovato, salto."; return 1; }

    log INFO "GPU ${idx} [${name}] profilo=${key} PL=${PL_W}W (core LIBERO/boost, mem stock) target=${TEMP_TARGET}C"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log INFO "DRY_RUN: salto applicazione hardware GPU ${idx}."
        return 0
    fi

    # Persistence mode (stabilita' 24/7).
    nsmi -i "$idx" -pm 1 >/dev/null 2>&1 || log WARN "GPU ${idx}: persistence mode non applicato."

    # --- Power limit (unico parametro applicato per pearlhash) ---------------
    # PL_W=0/vuoto => lascia il default del driver (NON forzare: es. 100W su una
    # RTX 5080 verrebbe rifiutato). Se impostato, lo CLAMPIAMO tra min e max
    # consentiti dalla scheda per evitare rifiuti.
    if [[ -n "$PL_W" && "$PL_W" != "0" ]]; then
        local minpl maxpl setpl="$PL_W"
        minpl="$(nsmi -i "$idx" --query-gpu=power.min_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | cut -d. -f1)"
        maxpl="$(nsmi -i "$idx" --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | cut -d. -f1)"
        if [[ "$maxpl" =~ ^[0-9]+$ ]] && (( setpl > maxpl )); then
            log WARN "GPU ${idx}: PL ${PL_W}W > max ${maxpl}W: uso ${maxpl}W."; setpl="$maxpl"
        fi
        if [[ "$minpl" =~ ^[0-9]+$ ]] && (( setpl < minpl )); then
            log WARN "GPU ${idx}: PL ${PL_W}W < min ${minpl}W: uso ${minpl}W."; setpl="$minpl"
        fi
        if nsmi -i "$idx" -pl "$setpl" >/dev/null 2>&1; then
            log INFO "GPU ${idx}: power limit ${setpl}W applicato (core lasciato in boost)."
        else
            log WARN "GPU ${idx}: power limit ${setpl}W rifiutato dal driver (proseguo con default)."
        fi
    else
        log INFO "GPU ${idx}: nessun power limit forzato (default driver, boost pieno)."
    fi

    # --- NIENTE lock core/mem: pearlhash e' compute-bound, il lock del core --
    # DIMEZZA l'hashrate. Lasciamo che la scheda faccia boost da sola.

    # --- Ventola iniziale dalla curva alla temperatura attuale --------------
    local temp fan_pct
    temp="$(nsmi -i "$idx" --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | tr -d ' ')"
    [[ "$temp" =~ ^[0-9]+$ ]] || temp="$TEMP_LO"
    fan_pct="$(fan_percent_for_temp "$temp" "$TEMP_LO" "$TEMP_HI" "$FAN_MIN" "$FAN_MAX")"
    if nsmi -i "$idx" --fan-speed="$fan_pct" >/dev/null 2>&1; then
        log INFO "GPU ${idx}: ventola ${fan_pct}% (temp=${temp}C curva ${TEMP_LO}-${TEMP_HI}C)."
    else
        log WARN "GPU ${idx}: controllo ventola non disponibile (alcune GPU richiedono coolbits/X)."
    fi

    # Stato per fan daemon e diagnostica.
    umask 077
    cat > "${MINEOS_STATE}/gpu-oc-${idx}.env" <<EOF
MODEL_KEY="${key}"
GPU_NAME="${name}"
PL_W="${PL_W}"
CORE_MHZ="${CORE_MHZ}"
MEM_OFFSET_MHZ="${MEM_OFF}"
TEMP_TARGET="${TEMP_TARGET}"
FAN_MIN="${FAN_MIN}"
FAN_MAX="${FAN_MAX}"
TEMP_LO="${TEMP_LO}"
TEMP_HI="${TEMP_HI}"
EOF
}

apply_all() {
    command -v nvidia-smi >/dev/null 2>&1 || { log WARN "nvidia-smi non trovato: salto OC."; return 0; }
    nsmi -L >/dev/null 2>&1 || { log WARN "Driver NVIDIA non attivo/ non risponde: salto OC."; return 0; }

    local idx name
    while IFS=',' read -r idx name; do
        idx="${idx// /}"
        name="${name# }"
        [[ -n "$idx" ]] || continue
        apply_one_gpu "$idx" "$name" || true
    done < <(nsmi --query-gpu=index,name --format=csv,noheader,nounits 2>/dev/null)

    # Aggiorna rig.conf con temp target piu' restrittivo tra le GPU (per watchdog).
    if [[ -f "${MINEOS_CONFIG}/rig.conf" && "${DRY_RUN:-0}" != "1" ]]; then
        local min_target=75 t f
        for f in "${MINEOS_STATE}"/gpu-oc-*.env; do
            [[ -f "$f" ]] || continue
            # shellcheck disable=SC1090
            source "$f"
            [[ -n "${TEMP_TARGET:-}" && "$TEMP_TARGET" -lt "$min_target" ]] && min_target="$TEMP_TARGET"
        done
        set_conf_value "${MINEOS_CONFIG}/rig.conf" GPU_TEMP_LIMIT_C "$min_target" 2>/dev/null || true
    fi

    log INFO "OC applicato. Riepilogo:"
    nsmi --query-gpu=index,name,power.limit,clocks.current.graphics,clocks.current.memory,temperature.gpu,fan.speed \
        --format=csv 2>/dev/null | tee -a "${MINEOS_LOGS}/mineos.log" >&2 || true
}

reset_all() {
    command -v nvidia-smi >/dev/null 2>&1 || { log WARN "nvidia-smi non trovato."; return 0; }
    local idx
    while read -r idx; do
        reset_gpu "$idx"
    done < <(nsmi --query-gpu=index --format=csv,noheader,nounits 2>/dev/null)
    rm -f "${MINEOS_STATE}"/gpu-oc-*.env 2>/dev/null || true
    log INFO "Reset OC completato su tutte le GPU."
}

main() {
    require_root
    mkdir -p "${MINEOS_STATE}" "${MINEOS_LOGS}" 2>/dev/null || true
    load_oc_conf

    if [[ "$RESET" -eq 1 ]]; then
        reset_all
        exit 0
    fi

    if [[ "${GPU_AUTO_OC:-false}" != "true" ]]; then
        log INFO "GPU_AUTO_OC disabilitato in gpu-oc.conf. Esco."
        exit 0
    fi

    log INFO "=== apply-gpu-oc (algo=${OC_ALGO:-pearlhash}) ==="
    apply_all

    # BUG2 FIX: NON chiamare 'systemctl restart' di un altro servizio da qui.
    # mineos-gpu-oc e' oneshot e mineos-gpu-fan e' 'After=mineos-gpu-oc': restartarlo
    # dall'interno creava un DEADLOCK (gpu-fan aspetta gpu-oc che aspetta gpu-fan),
    # appendendo tutta la coda di systemd. Il fan daemon parte da solo dopo di noi
    # (WantedBy=multi-user, After=mineos-gpu-oc). Nessuna azione qui.
    log INFO "OC completato. mineos-gpu-fan partira' automaticamente dopo questo servizio."
}

main "$@"
